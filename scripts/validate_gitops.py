#!/usr/bin/env python3
"""Offline Helm rendering, CRD schema and repository-specific contract checks.

No kubectl or AWS mutation is executed. --fetch downloads pinned public charts
into a cache, verifies their digests, then uses the same checks as offline mode.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urljoin

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[1]


class Loader(yaml.SafeLoader):
    """YAML 1.1 의 '=' 값 태그를 문자열로 읽는다(prometheus-operator CRD 의 enum 에 '=' 가 있다)."""


Loader.add_constructor('tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))
LOCAL_CHARTS = ['seed', 'root', 'foundation', 'secrets', 'data', 'apps', 'observability', 'sample']
APP_VALUE_FILES = {'apps': ['images.yaml']}
# Kubernetes 1.35 공식 OpenAPI. 자체 chart 의 기본 객체(Deployment 등)를 모르는 필드·형식 오류까지 엄격히 검사한다.
K8S_OPENAPI = {
    'url': 'https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/api/openapi-spec/swagger.json',
    'digest': '483500149ee52ce5753d75f5639101d985bb4f5e902cc05b1ba7627465d62446',
}
# Secrets Manager nerdnam/dev/data JSON 키 계약 (docs/데이터-계층-작업계획.md)
DATA_SECRET_KEYS = {'postgres-superuser-password', 'postgres-migrator-password', 'postgres-app-password', 'redis-api-password',
                    'postgres-exporter-password', 'redis-exporter-password'}
OTLP_HTTP_PORT = 4318   # 앱 → Alloy (8단계)
TEMPO_OTLP_GRPC_PORT = 4317   # Alloy → Tempo
BACKEND_FROM_DATA = {'SPRING_DATASOURCE_PASSWORD': 'postgres-app-password',
                     'SPRING_FLYWAY_PASSWORD': 'postgres-migrator-password',
                     'SPRING_DATA_REDIS_PASSWORD': 'redis-api-password'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helm', default='helm')
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true')
    args = parser.parse_args()
    args.cache = args.cache.expanduser().resolve()
    args.cache.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / 'gitops/charts.lock.json').read_text())
    fixture = ROOT / 'tests/fixtures/gitops-values.yaml'
    lbc = lock['aws-load-balancer-controller']
    assert '/' + lbc['appVersion'] + '/' in lbc['iamPolicy']['url']
    assert hashlib.sha256((ROOT / 'modules/platform/lbc-iam-policy.json').read_bytes()).hexdigest() == lbc['iamPolicy']['digest']

    def run(command):
        return subprocess.check_output(command, text=True, cwd=ROOT)

    def render(name, chart, namespace, values, extra=()):
        files = [x for value in [*extra, values] for x in ('-f', str(value))]
        raw = run([args.helm, 'template', name, str(chart), '--namespace', namespace,
                   '--kube-version', '1.35.0', '--include-crds', *files])
        docs = [x for x in yaml.load_all(raw, Loader=Loader) if x]
        assert len({(x['apiVersion'], x['kind'], x['metadata'].get('namespace', namespace), x['metadata']['name']) for x in docs}) == len(docs), name
        return docs

    for name, item in lock.items():
        archive = args.cache / (name + '.tgz')
        if not archive.exists() and args.fetch:
            subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                            urljoin(item['repo'] + '/', item['url']), '-o', str(archive)], check=True)
        if not archive.exists():
            raise RuntimeError(f'{archive} missing; use --fetch to fill the cache')
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == item['digest'], f'{name}: checksum mismatch'

    openapi = args.cache / 'kubernetes-openapi-v1.35.0.json'
    if not openapi.exists() and args.fetch:
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', K8S_OPENAPI['url'], '-o', str(openapi)], check=True)
    if not openapi.exists():
        raise RuntimeError(f'{openapi} missing; use --fetch to fill the cache')
    assert hashlib.sha256(openapi.read_bytes()).hexdigest() == K8S_OPENAPI['digest'], 'kubernetes openapi checksum mismatch'
    core = CoreSchema(json.loads(openapi.read_text())['definitions'])

    local = {}
    for name in LOCAL_CHARTS:
        chart = ROOT / 'gitops' / name
        # Argo 와 같은 순서: Application 의 valueFiles(chart 안 파일) 다음 valuesObject(환경 값).
        extra = [chart / f for f in APP_VALUE_FILES.get(name, [])]
        run([args.helm, 'lint', str(chart), '--strict', '--kube-version', '1.35.0', *[x for f in [*extra, fixture] for x in ('-f', str(f))]])
        local[name] = render('nerdnam-' + name, chart, 'argocd' if name in ['seed', 'root'] else 'nerdnam', fixture, extra)

    upstream = {'argo-cd': render('argocd', args.cache / 'argo-cd.tgz', 'argocd', ROOT / 'bootstrap/argocd-values.yaml')}
    with tempfile.TemporaryDirectory(prefix='nerdnam-render-') as directory:
        for app in local['root']:
            source = app['spec']['source']
            if 'chart' not in source:
                continue
            name = app['metadata']['name']
            assert source['targetRevision'] == lock[name]['version']
            assert source['repoURL'] == lock[name]['repo']
            values = Path(directory) / (name + '.yaml')
            values.write_text(yaml.safe_dump(source['helm']['valuesObject']))
            upstream[name] = render(name, args.cache / (name + '.tgz'), app['spec']['destination']['namespace'], values)

    # Validate our CRs against the actual CRDs shipped with pinned controller charts.
    schemas = {}
    for docs in upstream.values():
        for doc in docs:
            if doc['kind'] == 'CustomResourceDefinition':
                spec = doc['spec']
                for version in spec['versions']:
                    if version.get('served'):
                        schemas[(spec['group'] + '/' + version['name'], spec['names']['kind'])] = version['schema']['openAPIV3Schema']
    custom_count = 0
    core_count = 0
    for docs in local.values():
        for doc in docs:
            group = doc['apiVersion'].split('/')[0]
            if group in ['argoproj.io', 'cert-manager.io', 'external-secrets.io', 'monitoring.coreos.com']:
                schema = schemas[(doc['apiVersion'], doc['kind'])]
                jsonschema.Draft7Validator(schema).validate(doc)
                custom_count += 1
            else:
                core.validate(doc)
                core_count += 1
            assert doc['kind'] != 'Secret', 'Do not put secret values in local GitOps charts'
            assert doc['kind'] != 'HorizontalPodAutoscaler'

    apps = [x for docs in [local['seed'], local['root']] for x in docs if x['kind'] == 'Application']
    assert all('automated' not in x['spec'].get('syncPolicy', {}) for x in apps)
    assert all(not x['metadata'].get('finalizers') for x in apps)

    services = [x for docs in upstream.values() for x in docs if x['kind'] == 'Service']
    public = [x for x in services if x['spec'].get('type') == 'LoadBalancer']
    assert len(public) == 1
    lb = public[0]
    assert lb['spec']['loadBalancerClass'] == 'service.k8s.aws/nlb'
    assert {x['port'] for x in lb['spec']['ports']} == {80, 443}
    assert all(x['protocol'] == 'TCP' for x in lb['spec']['ports'])
    assert lb['metadata']['annotations']['service.beta.kubernetes.io/aws-load-balancer-nlb-target-type'] == 'ip'
    assert not any('aws-load-balancer-ssl' in x for x in lb['metadata']['annotations'])

    scheduled = 0
    for chart, docs in upstream.items():
        for doc in docs:
            if doc['kind'] not in ['Deployment', 'StatefulSet', 'Job']:
                continue
            pod = doc['spec']['template']['spec']
            expected = 'app' if chart == 'traefik' else 'platform'
            if chart == 'kube-prometheus-stack' and doc['kind'] == 'Job' and 'admission' not in doc['metadata']['name']:
                raise AssertionError(f'unexpected job {doc["metadata"]["name"]}')
            assert pod.get('nodeSelector', {}).get('workload') == expected, f'{chart}/{doc["metadata"]["name"]}: placement'
            if expected == 'platform':
                assert any(t.get('key') == 'dedicated' and t.get('value') == 'platform' and t.get('effect') == 'NoSchedule'
                           for t in pod.get('tolerations', [])), f'{chart}: missing toleration'
            scheduled += 1

    # LBC webhook 인증서는 cert-manager 가 발급한다. 차트가 직접 만들면 렌더마다 값이 바뀌어 Argo 가 늘 OutOfSync 다.
    lbc_docs = upstream['aws-load-balancer-controller']
    assert not any(x['kind'] == 'Secret' for x in lbc_docs), 'LBC must not render its own TLS secret (use enableCertManager)'
    assert any(x['kind'] == 'Certificate' for x in lbc_docs), 'LBC webhook certificate comes from cert-manager'
    obs_count = check_observability(local, upstream)

    by_kind = {doc['kind']: doc for doc in local['sample']}
    assert by_kind['Ingress']['spec']['tls'][0]['secretName'] == by_kind['Certificate']['spec']['secretName']
    assert by_kind['Ingress']['spec']['rules'][0]['host'] == by_kind['Certificate']['spec']['dnsNames'][0]
    assert by_kind['Service']['spec'].get('type', 'ClusterIP') == 'ClusterIP'
    storage = next(x for x in local['foundation'] if x['kind'] == 'StorageClass')
    assert storage['reclaimPolicy'] == 'Retain' and storage['volumeBindingMode'] == 'WaitForFirstConsumer'
    assert storage['parameters']['encrypted'] == 'true'
    store = next(x for x in local['foundation'] if x['kind'] == 'ClusterSecretStore')
    assert 'auth' not in store['spec']['provider']['aws'], 'Pod Identity uses ambient credentials'
    assert store['spec']['conditions'][0]['namespaces'] == ['nerdnam', 'data', 'monitoring']
    assert all(x['spec']['target']['deletionPolicy'] == 'Retain' for x in local['secrets'])

    # Missing environment values must fail; example fixtures must not become defaults.
    data_count = check_data_layer(local)
    app_count = check_apps(local)
    capacity, _ = check_capacity(local, upstream)
    dashboard_count, query_count = check_queries(local)

    rejected = subprocess.run([args.helm, 'template', 'missing-values', str(ROOT / 'gitops/root')],
                              capture_output=True, text=True)
    assert rejected.returncode != 0
    print(f'PASS: {len(LOCAL_CHARTS)} local charts, {len(lock)} pinned upstream charts, '
          f'{custom_count} custom resources, {core_count} core objects (strict 1.35 schema), {scheduled} scheduling checks')
    print('PASS: NLB/TLS, secret boundaries, storage retention and missing-input checks')
    print(f'PASS: data layer ({data_count} StatefulSets): placement, PVC retention, pinned images, '
          'pod security, probes, secret keys, quota and BE<->data network policies')
    print(f'PASS: observability ({obs_count} scrape targets): platform placement incl. Prometheus/Alertmanager, retained PVCs, '
          'Loki on S3 via Pod Identity, least-privilege Alloy RBAC, ServiceMonitor<->Service<->NetworkPolicy match')
    print('PASS: tracing: apps OTEL env -> Alloy OTLP HTTP (egress policy) -> Tempo OTLP gRPC only, Tempo on S3 via Pod Identity, '
          'read-only root, Grafana Tempo<->Loki links')
    print(f'PASS: apps ({app_count} Deployments): digest-pinned ECR images, placement, pod security, probes, '
          'public routes, Bedrock identity and namespace traffic policies')
    print(f'PASS: queries ({dashboard_count} dashboards, {query_count} PromQL incl. alert rules): metric names exist '
          '(collected fixtures + cluster metrics), job/namespace match ServiceMonitors, datasource uids')
    print(f'PASS: capacity (estimated allocatable, requests <= {REQUEST_HEADROOM:.0%}, data node limits not overcommitted):')
    for line in capacity:
        print('  ' + line)



class CoreSchema:
    """Kubernetes OpenAPI(v2) 정의로 기본 객체를 검사한다. 정의에 없는 필드는 오류로 본다(kubectl --validate=strict 와 같은 취지)."""

    def __init__(self, definitions):
        self.defs = definitions
        self.by_kind = {}
        for name, schema in definitions.items():
            for gvk in schema.get('x-kubernetes-group-version-kind', []):
                api = (gvk['group'] + '/' if gvk['group'] else '') + gvk['version']
                self.by_kind[(api, gvk['kind'])] = name

    def validate(self, doc):
        key = (doc['apiVersion'], doc['kind'])
        assert key in self.by_kind, f'unknown core kind {key}'
        self._check(doc, {'$ref': '#/definitions/' + self.by_kind[key]}, f"{doc['kind']}/{doc['metadata']['name']}")

    def _check(self, value, schema, path):
        if '$ref' in schema:
            name = schema['$ref'].rsplit('/', 1)[-1]
            if name in ('io.k8s.apimachinery.pkg.api.resource.Quantity', 'io.k8s.apimachinery.pkg.util.intstr.IntOrString'):
                assert isinstance(value, (str, int, float)) and not isinstance(value, bool), f'{path}: {name}'
                return
            schema = self.defs[name]
        kind = schema.get('type')
        if kind == 'object' or 'properties' in schema:
            assert isinstance(value, dict), f'{path}: expected object'
            props = schema.get('properties', {})
            for field in schema.get('required', []):
                assert field in value, f'{path}: missing required {field}'
            for field, item in value.items():
                if field in props:
                    self._check(item, props[field], f'{path}.{field}')
                elif 'additionalProperties' in schema:
                    self._check(item, schema['additionalProperties'], f'{path}.{field}')
                else:
                    raise AssertionError(f'{path}: unknown field {field!r}')
        elif kind == 'array':
            assert isinstance(value, list), f'{path}: expected list'
            for i, item in enumerate(value):
                self._check(item, schema['items'], f'{path}[{i}]')
        elif kind == 'string':
            assert isinstance(value, str), f'{path}: expected string, got {value!r}'
        elif kind == 'integer':
            assert isinstance(value, int) and not isinstance(value, bool), f'{path}: expected integer'
        elif kind == 'boolean':
            assert isinstance(value, bool), f'{path}: expected boolean'


def check_apps(local):
    docs = local['apps']
    by_kind = {}
    for doc in docs:
        by_kind.setdefault(doc['kind'], []).append(doc)
    assert all(x['metadata']['namespace'] == 'nerdnam' for x in docs if x['kind'] != 'Namespace')
    root_apps = {x['metadata']['name']: x for x in local['root'] if x['kind'] == 'Application'}
    source = root_apps['nerdnam-apps']['spec']['source']
    assert source['path'] == 'gitops/apps' and source['helm']['valueFiles'] == APP_VALUE_FILES['apps']
    # Git 의 images.yaml 만으로는(첫 이미지 digest 를 넣기 전) 렌더링이 실패해야 한다: 가짜 이미지 기본값 금지.
    committed = yaml.safe_load((ROOT / 'gitops/apps/images.yaml').read_text())['images']
    assert set(committed) == {'web', 'api', 'ai'}
    for name, ref in committed.items():
        assert ref == '' or re.fullmatch(r'\d{12}\.dkr\.ecr\.ap-northeast-2\.amazonaws\.com/nerdnam-dev/' + name + r'@sha256:[0-9a-f]{64}', ref), \
            f'gitops/apps/images.yaml: {name} must be empty or an ECR digest of nerdnam-dev/{name}'

    deployments = {x['metadata']['name']: x for x in by_kind['Deployment']}
    assert set(deployments) == {'web', 'api', 'ai'}
    services = {x['metadata']['name']: x for x in by_kind['Service']}
    accounts = {x['metadata']['name'] for x in by_kind['ServiceAccount']}
    ports = {}
    for name, deployment in deployments.items():
        spec = deployment['spec']
        pod = spec['template']['spec']
        where = f'nerdnam/{name}'
        labels = spec['template']['metadata']['labels']
        assert labels == spec['selector']['matchLabels'] == {'app': name}, where
        assert spec['replicas'] == 1, where
        assert pod['nodeSelector'] == {'workload': 'app'} and 'tolerations' not in pod, where
        assert pod['serviceAccountName'] == name and name in accounts, where
        assert pod['automountServiceAccountToken'] is False and pod['enableServiceLinks'] is False, where
        assert pod['securityContext']['runAsNonRoot'] is True and pod['securityContext']['runAsUser'] > 0, where
        (container,) = pod['containers']
        assert re.fullmatch(r'\d{12}\.dkr\.ecr\.ap-northeast-2\.amazonaws\.com/nerdnam-dev/' + name + r'@sha256:[0-9a-f]{64}',
                            container['image']), f'{where}: image must be the {name} ECR repository pinned by digest'
        security = container['securityContext']
        assert security['readOnlyRootFilesystem'] is True and security['allowPrivilegeEscalation'] is False, where
        assert security['capabilities']['drop'] == ['ALL'], where
        assert 'readinessProbe' in container and 'livenessProbe' in container, where
        assert 'memory' in container['resources']['limits'] and 'cpu' in container['resources']['requests'], where
        env = {e['name']: e.get('value') for e in container.get('env', [])}
        assert not any(k.startswith('AWS_ACCESS_KEY') or k in ('AWS_SECRET_ACCESS_KEY', 'AWS_BEARER_TOKEN_BEDROCK') for k in env), \
            f'{where}: no static AWS credentials'
        ports[name] = container['ports'][0]['containerPort']
        service = services[name]
        assert service['spec'].get('type', 'ClusterIP') == 'ClusterIP' and service['spec']['selector'] == {'app': name}, where
        assert service['spec']['ports'][0]['port'] == ports[name] and service['spec']['ports'][0]['name'] == 'http', where
        assert all(p['name'] in ('http', 'management') for p in container['ports']), where

    api = deployments['api']
    assert api['spec']['strategy'] == {'type': 'Recreate'}, 'Flyway at startup: never run two BE versions together'
    api_container = api['spec']['template']['spec']['containers'][0]
    api_env = {e['name']: e.get('value') for e in api_container['env']}
    # actuator 는 관리 포트에만 있다(BE #42·#44): probe 는 그 포트의 liveness·readiness 그룹을 본다.
    management = next(p['containerPort'] for p in api_container['ports'] if p['name'] == 'management')
    assert api_env['MANAGEMENT_PORT'] == str(management) and management != ports['api']
    assert api_container['livenessProbe']['httpGet'] == {'path': '/actuator/health/liveness', 'port': 'management'}
    assert api_container['startupProbe']['httpGet'] == {'path': '/actuator/health/liveness', 'port': 'management'}
    assert api_container['readinessProbe']['httpGet'] == {'path': '/actuator/health/readiness', 'port': 'management'}
    assert {'name': 'management', 'port': management, 'targetPort': 'management'} in services['api']['spec']['ports']
    # web probe 는 FE 상태 확인 전용 경로(FE #11). 화면 경로를 쓰면 probe 마다 SSR·BE 호출·trace 가 생긴다.
    web_container = deployments['web']['spec']['template']['spec']['containers'][0]
    assert web_container['readinessProbe']['httpGet'] == {'path': '/healthz', 'port': 'http'}
    assert web_container['livenessProbe']['httpGet'] == {'path': '/healthz', 'port': 'http'}
    ai_container = deployments['ai']['spec']['template']['spec']['containers'][0]
    assert ai_container['livenessProbe']['httpGet']['path'] == '/livez' and ai_container['readinessProbe']['httpGet']['path'] == '/readyz'
    # AI 이미지의 uvicorn 종료 대기(300초)보다 종료 유예가 길어야 진행 중 요청을 끝낸다(AI #34).
    assert deployments['ai']['spec']['template']['spec']['terminationGracePeriodSeconds'] > 300
    assert api_env['SPRING_PROFILES_ACTIVE'] not in ('local', '', None)
    assert api_env['SPRING_DATASOURCE_USERNAME'] == 'nerdnam_app' and api_env['SPRING_FLYWAY_USER'] == 'nerdnam_migrator'
    assert api_env['SPRING_DATASOURCE_URL'] == 'jdbc:postgresql://postgres.data.svc.cluster.local:5432/nerdnam'
    assert api_env['REDIS_HOST'] == 'redis.data.svc.cluster.local' and api_env['SPRING_DATA_REDIS_USERNAME'] == 'api'
    assert api_env['NERDNAM_AI_STUB'] == 'false' and api_env['NERDNAM_AUTH_MODE'] == 'session'
    assert api_env['NERDNAM_AI_BASE_URL'] == f'http://ai.nerdnam.svc.cluster.local:{ports["ai"]}'
    assert api_container['envFrom'] == [{'secretRef': {'name': 'backend-secrets'}}]
    passwords = set(BACKEND_FROM_DATA)
    assert not passwords & set(api_env), 'passwords come from backend-secrets only'
    web_env = {e['name']: e.get('value') for e in deployments['web']['spec']['template']['spec']['containers'][0]['env']}
    assert web_env['API_ORIGIN'] == f'http://api.nerdnam.svc.cluster.local:{ports["api"]}'
    ai_env = {e['name']: e.get('value') for e in deployments['ai']['spec']['template']['spec']['containers'][0]['env']}
    assert ai_env['AI_MODE'] == 'real' and ai_env['LLM_MODEL'].startswith('global.')
    assert all('envFrom' not in d['spec']['template']['spec']['containers'][0] for n, d in deployments.items() if n != 'api')

    # 공개 경로: 로그인·API 만 BE, 나머지는 FE. TLS 는 같은 host 의 인증서.
    (ingress,) = by_kind['Ingress']
    (cert,) = by_kind['Certificate']
    rule = ingress['spec']['rules'][0]
    assert ingress['spec']['tls'][0]['secretName'] == cert['spec']['secretName']
    assert ingress['spec']['tls'][0]['hosts'] == cert['spec']['dnsNames'] == [rule['host']]
    routes = {p['path']: (p['backend']['service']['name'], p['backend']['service']['port']['number']) for p in rule['http']['paths']}
    assert routes == {'/api': ('api', ports['api']), '/oauth2': ('api', ports['api']),
                      '/login/oauth2': ('api', ports['api']), '/': ('web', ports['web'])}
    assert all(p['pathType'] == 'Prefix' for p in rule['http']['paths'])

    # 통신 정책: 누가 누구에게 닿는지를 Pod 쌍으로 계산해 기대값과 비교한다.
    policies = {x['metadata']['name']: x['spec'] for x in by_kind['NetworkPolicy']}
    ingress_from = {}
    for spec in policies.values():
        if 'Ingress' not in spec['policyTypes']:
            continue
        target = spec['podSelector']['matchLabels']['app']
        for rule_ in spec['ingress']:
            for peer in rule_['from']:
                source = peer.get('podSelector', {}).get('matchLabels', {}).get('app') or \
                    'ns:' + peer['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name']
                for port in rule_['ports']:
                    ingress_from.setdefault(target, set()).add((source, port['port']))
    assert ingress_from == {'web': {('ns:traefik', ports['web'])},
                            'api': {('ns:traefik', ports['api']), ('web', ports['api']), ('ns:monitoring', management)},
                            'ai': {('api', ports['ai'])}}
    egress_to = {}
    for spec in policies.values():
        if 'Egress' not in spec['policyTypes']:
            continue
        source = spec['podSelector']['matchLabels']['app']
        for rule_ in spec['egress']:
            for peer in rule_['to']:
                if 'ipBlock' in peer:
                    target = peer['ipBlock']['cidr']
                    if target == '0.0.0.0/0':
                        assert {'10.0.0.0/8', '169.254.0.0/16'} <= set(peer['ipBlock']['except']), 'internet rule must exclude private ranges'
                elif 'namespaceSelector' in peer:
                    # 다른 namespace 는 namespace 와 Pod 를 함께 고른 경우만 허용한다(namespace 전체로 열지 않는다).
                    target = (peer['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'] + '/'
                              + peer['podSelector']['matchLabels']['app.kubernetes.io/name'])
                else:
                    target = peer['podSelector']['matchLabels']['app']
                for port in rule_['ports']:
                    egress_to.setdefault(source, set()).add((target, port['port']))
    otlp = ('monitoring/alloy', OTLP_HTTP_PORT)
    assert egress_to == {'web': {('api', ports['api']), otlp},
                         'api': {('ai', ports['ai']), ('0.0.0.0/0', 443), otlp},
                         'ai': {('169.254.170.23/32', 80), ('0.0.0.0/0', 443), otlp}}

    # 8단계 trace: 앱마다 표준 OTEL_* 로 Alloy 에 trace 만 보낸다. service.name 은 Loki 의 app 라벨과 같아야
    # Grafana 가 trace → 로그로 간다.
    for name, deployment in deployments.items():
        container = deployment['spec']['template']['spec']['containers'][0]
        env = {e['name']: e.get('value') for e in container['env']}
        assert env['OTEL_SERVICE_NAME'] == name == deployment['spec']['template']['metadata']['labels']['app'], name
        assert env['OTEL_EXPORTER_OTLP_ENDPOINT'] == f'http://alloy.monitoring.svc.cluster.local:{OTLP_HTTP_PORT}', name
        assert env['OTEL_EXPORTER_OTLP_PROTOCOL'] == 'http/protobuf', name
        assert env['OTEL_TRACES_EXPORTER'] == 'otlp' and env['OTEL_METRICS_EXPORTER'] == env['OTEL_LOGS_EXPORTER'] == 'none', \
            f'{name}: metrics come from Prometheus and logs from stdout; OTLP carries traces only'
        assert env['OTEL_TRACES_SAMPLER'] == 'parentbased_traceidratio' and 0 < float(env['OTEL_TRACES_SAMPLER_ARG']) <= 1, name
        # $(K8S_POD_NAME) 는 앞에 정의된 env 만 치환된다.
        names = [e['name'] for e in container['env']]
        assert names.index('K8S_POD_NAME') < names.index('OTEL_RESOURCE_ATTRIBUTES'), name
        assert 'k8s.pod.name=$(K8S_POD_NAME)' in env['OTEL_RESOURCE_ATTRIBUTES'], name
    data_egress = next(x for x in local['data'] if x['kind'] == 'NetworkPolicy' and x['metadata']['name'] == 'allow-api-to-data')
    assert data_egress['spec']['podSelector']['matchLabels'] == {'app': 'api'}, 'data chart must select the same BE pods'

    quota = by_kind['ResourceQuota'][0]['spec']['hard']
    assert quota['services.loadbalancers'] == '0' and quota['services.nodeports'] == '0'
    surge = {'web': 2, 'api': 1, 'ai': 2}   # RollingUpdate maxSurge 1 이면 교체 중 2개
    sample = next(x for x in local['sample'] if x['kind'] == 'Deployment')['spec']['template']['spec']['containers'][0]['resources']
    cpu = sum(quantity(d['spec']['template']['spec']['containers'][0]['resources']['requests']['cpu']) * surge[n] for n, d in deployments.items())
    memory = sum(quantity(d['spec']['template']['spec']['containers'][0]['resources']['limits']['memory']) * surge[n] for n, d in deployments.items())
    assert cpu + quantity(sample['requests']['cpu']) <= quantity(quota['requests.cpu']), 'quota blocks rolling update'
    assert memory + quantity(sample['limits']['memory']) <= quantity(quota['limits.memory']), 'quota blocks rolling update'
    return len(deployments)


def check_observability(local, upstream):
    def tolerates(pod):
        return any(t.get('key') == 'dedicated' and t.get('value') == 'platform' for t in pod.get('tolerations', []))
    # operator 가 만드는 Prometheus·Alertmanager 도 platform 노드, PVC 는 gp3-retain.
    stack = upstream['kube-prometheus-stack']
    for kind in ['Prometheus', 'Alertmanager']:
        (cr,) = [x for x in stack if x['kind'] == kind]
        spec = cr['spec']
        assert spec['nodeSelector'].get('workload') == 'platform' and tolerates(spec), kind
        assert spec['storage']['volumeClaimTemplate']['spec']['storageClassName'] == 'gp3-retain', kind
    prom = next(x for x in stack if x['kind'] == 'Prometheus')['spec']
    assert prom['retention'] == '7d' and prom['retentionSize'] == '20GB'
    assert prom['serviceMonitorSelector'] == {} and prom['ruleSelector'] == {}, 'local ServiceMonitor/PrometheusRule must be selected'
    grafana = next(x for x in stack if x['kind'] == 'Deployment' and x['metadata']['name'] == 'grafana')['spec']['template']['spec']
    assert grafana['nodeSelector'].get('workload') == 'platform' and tolerates(grafana)
    assert not any(e['name'] == 'GF_SECURITY_ADMIN_PASSWORD' and 'value' in e for c in grafana['containers'] for e in c.get('env', [])), \
        'Grafana admin password must come from a Secret'
    assert any(e.get('valueFrom', {}).get('secretKeyRef', {}).get('name') == 'monitoring-secrets'
               for c in grafana['containers'] for e in c.get('env', [])), 'Grafana admin from ExternalSecret'
    claims = [x for x in stack if x['kind'] == 'PersistentVolumeClaim']
    assert claims and all(x['spec']['storageClassName'] == 'gp3-retain' for x in claims)
    node_exporter = next(x for x in stack if x['kind'] == 'DaemonSet')['spec']['template']['spec']
    assert any(t.get('operator') == 'Exists' for t in node_exporter['tolerations']), 'node-exporter must run on every node'
    assert not any(x['kind'] in ('Ingress',) for docs in [stack, upstream['loki'], upstream['alloy'], upstream['tempo']] for x in docs)

    # Loki: S3 + Pod Identity(SA 이름이 Terraform association 과 같아야 한다). 정적 키 없음.
    loki = upstream['loki']
    (sts,) = [x for x in loki if x['kind'] == 'StatefulSet']
    assert sts['spec']['template']['spec']['serviceAccountName'] == 'loki'
    assert sts['spec']['template']['spec']['nodeSelector'].get('workload') == 'platform' and tolerates(sts['spec']['template']['spec'])
    assert sts['spec']['volumeClaimTemplates'][0]['spec']['storageClassName'] == 'gp3-retain'
    assert not [x for x in loki if x['kind'] in ('Deployment', 'StatefulSet') and x is not sts], 'SingleBinary only (no gateway/cache/canary)'
    config = next(yaml.safe_load(x['data']['config.yaml']) for x in loki if x['kind'] == 'ConfigMap' and 'config.yaml' in x.get('data', {}))
    s3 = config['common']['storage']['s3']
    assert s3['bucketnames'] == 'nerdnam-dev-loki-082139775699-ap-northeast-2' and 'access_key_id' not in s3 and 'secret_access_key' not in s3
    assert config['limits_config']['retention_period'] == '168h' and config['compactor']['retention_enabled'] is True
    assert config['auth_enabled'] is False

    # Alloy: Secret·ConfigMap 을 읽지 못한다(차트 기본 권한을 줄였다).
    alloy = upstream['alloy']
    for role in [x for x in alloy if x['kind'] in ('ClusterRole', 'Role')]:
        for rule in role['rules']:
            assert not {'secrets', 'configmaps'} & set(rule.get('resources', [])), f'alloy RBAC too broad: {rule}'
            assert set(rule['verbs']) <= {'get', 'list', 'watch'}
    (alloy_deploy,) = [x for x in alloy if x['kind'] == 'Deployment']
    assert alloy_deploy['spec']['template']['spec']['nodeSelector'].get('workload') == 'platform'
    assert not any('hostPath' in v for v in alloy_deploy['spec']['template']['spec'].get('volumes', []))
    alloy_config = next(x['data']['config.alloy'] for x in alloy if x['kind'] == 'ConfigMap' and 'config.alloy' in x.get('data', {}))
    assert 'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push' in alloy_config

    # 8단계 trace 경로: 앱 → Alloy OTLP HTTP → Tempo OTLP gRPC. 이름·포트·라벨이 세 차트 사이에서 맞아야 한다.
    alloy_pod = alloy_deploy['spec']['template']
    assert alloy_pod['metadata']['labels'].get('app.kubernetes.io/name') == 'alloy', 'apps egress selects alloy pods by this label'
    alloy_ports = {p['containerPort'] for c in alloy_pod['spec']['containers'] for p in c.get('ports', [])}
    assert OTLP_HTTP_PORT in alloy_ports
    (alloy_service,) = [x for x in alloy if x['kind'] == 'Service' and x['metadata']['name'] == 'alloy']
    assert any(p['port'] == OTLP_HTTP_PORT for p in alloy_service['spec']['ports'])
    assert f'endpoint = "0.0.0.0:{OTLP_HTTP_PORT}"' in alloy_config and 'grpc {' not in alloy_config, 'Alloy receives OTLP over HTTP only'
    assert f'endpoint = "tempo.monitoring.svc.cluster.local:{TEMPO_OTLP_GRPC_PORT}"' in alloy_config
    assert 'otelcol.processor.memory_limiter' in alloy_config, 'trace spikes must not OOM the log collector'
    for signal in ('metrics', 'logs'):
        assert f'{signal} =' not in alloy_config.split('otelcol.receiver.otlp', 1)[1], f'OTLP {signal} would duplicate Prometheus/Loki'

    # Tempo: monolithic 1개, S3 + Pod Identity(SA 이름이 Terraform association 과 같아야 한다), 정적 키 없음.
    tempo = upstream['tempo']
    (tempo_sts,) = [x for x in tempo if x['kind'] == 'StatefulSet']
    assert not [x for x in tempo if x['kind'] in ('Deployment', 'StatefulSet', 'DaemonSet', 'Ingress') and x is not tempo_sts]
    tempo_pod = tempo_sts['spec']['template']['spec']
    assert tempo_pod['serviceAccountName'] == 'tempo' and tempo_sts['spec']['replicas'] == 1
    assert tempo_pod['nodeSelector'].get('workload') == 'platform' and tolerates(tempo_pod)
    assert tempo_sts['spec']['volumeClaimTemplates'][0]['spec']['storageClassName'] == 'gp3-retain'
    (tempo_container,) = tempo_pod['containers']
    assert tempo_container['securityContext']['readOnlyRootFilesystem'] is True
    assert tempo_container['securityContext']['capabilities']['drop'] == ['ALL']
    assert tempo_pod['securityContext']['runAsNonRoot'] is True
    assert 'limits' in tempo_container['resources'] and 'requests' in tempo_container['resources']
    assert not any(e['name'].startswith('AWS_') for e in tempo_container.get('env') or [])
    tempo_cm = next(x for x in tempo if x['kind'] == 'ConfigMap' and 'tempo.yaml' in x.get('data', {}))
    tempo_config = yaml.safe_load(tempo_cm['data']['tempo.yaml'])
    trace = tempo_config['storage']['trace']
    assert trace['backend'] == 's3' and trace['s3']['bucket'] == 'nerdnam-dev-tempo-082139775699-ap-northeast-2'
    assert not {'access_key', 'secret_key', 'insecure'} & set(trace['s3']), 'Pod Identity and TLS only'
    assert trace['wal']['path'].startswith('/var/tempo/'), 'WAL must be on the PVC'
    assert tempo_config['distributor']['receivers'] == {'otlp': {'protocols': {'grpc': {'endpoint': f'0.0.0.0:{TEMPO_OTLP_GRPC_PORT}'}}}}, \
        'Tempo listens only for Alloy (no Jaeger/Zipkin/OTLP HTTP)'
    assert tempo_config['backend_worker']['compaction']['block_retention'] == '72h'
    assert tempo_config['backend_scheduler']['provider']['compaction']['compaction']['block_retention'] == '72h'
    assert tempo_config['usage_report']['reporting_enabled'] is False and tempo_config['multitenancy_enabled'] is False
    (tempo_service,) = [x for x in tempo if x['kind'] == 'Service' and x['metadata']['name'] == 'tempo']
    assert {TEMPO_OTLP_GRPC_PORT, 3200} <= {p['port'] for p in tempo_service['spec']['ports']}
    assert tempo_service['spec'].get('type', 'ClusterIP') == 'ClusterIP'

    # Grafana: Tempo 데이터 소스와 로그 ↔ trace 연결. uid 가 서로를 가리킨다.
    datasources = [d for x in stack if x['kind'] == 'ConfigMap' for key, text in x.get('data', {}).items()
                   if key.endswith('.yaml') and 'datasources:' in text for d in yaml.safe_load(text)['datasources']]
    by_uid = {d.get('uid'): d for d in datasources}
    assert by_uid['tempo']['type'] == 'tempo' and by_uid['tempo']['url'] == 'http://tempo.monitoring.svc.cluster.local:3200'
    assert by_uid['tempo']['jsonData']['tracesToLogsV2']['datasourceUid'] == 'loki'
    assert {'key': 'service.name', 'value': 'app'} in by_uid['tempo']['jsonData']['tracesToLogsV2']['tags'], \
        'service.name(OTEL_SERVICE_NAME) maps to the Loki app label set by Alloy'
    (derived,) = by_uid['loki']['jsonData']['derivedFields']
    assert derived['datasourceUid'] == 'tempo'
    # Grafana 는 provisioning 파일의 ${...} 를 환경 변수로 바꾼다. $$ 로 써야 ${__value.raw} 가 남는다.
    assert derived['url'] == '$${__value.raw}'
    trace_id = 'ab' * 16
    for line in [f'{{"level":"INFO","trace_id":"{trace_id}","span_id":"{"cd" * 8}"}}', f'level=INFO trace_id={trace_id} msg=ok',
                 f'{{"traceId":"{trace_id}"}}']:
        assert re.search(derived['matcherRegex'], line).group(1) == trace_id, line
    assert not re.search(derived['matcherRegex'], '{"member_id":"' + 'ab' * 16 + '"}')
    assert '__meta_kubernetes_pod_label_app' in alloy_config and 'target_label  = "app"' in alloy_config

    # ServiceMonitor → Service(라벨·포트 이름) → NetworkPolicy(Prometheus 허용)가 서로 맞는지.
    services = {(x['metadata']['namespace'], x['metadata']['name']): x for chart in ['apps', 'data'] for x in local[chart] if x['kind'] == 'Service'}
    policies = [x for chart in ['apps', 'data'] for x in local[chart] if x['kind'] == 'NetworkPolicy']
    monitors = [x for x in local['observability'] if x['kind'] == 'ServiceMonitor']
    for monitor in monitors:
        namespace = monitor['metadata']['namespace']
        selector = monitor['spec']['selector']['matchLabels']
        matched = [s for (ns, _), s in services.items() if ns == namespace and selector.items() <= s['metadata'].get('labels', {}).items()]
        assert len(matched) == 1, f'{namespace}/{monitor["metadata"]["name"]}: selects {len(matched)} services'
        service = matched[0]
        port_name = monitor['spec']['endpoints'][0]['port']
        port = next(p for p in service['spec']['ports'] if p['name'] == port_name)
        pod_labels = service['spec']['selector']
        target_port = port['targetPort']
        def allows(policy):
            spec = policy['spec']
            if policy['metadata']['namespace'] != namespace or 'Ingress' not in spec['policyTypes']:
                return False
            if not spec['podSelector'].get('matchLabels', {}).items() <= pod_labels.items():
                return False
            for rule in spec.get('ingress', []):
                from_prometheus = any(p.get('namespaceSelector', {}).get('matchLabels') == {'kubernetes.io/metadata.name': 'monitoring'}
                                      and p.get('podSelector', {}).get('matchLabels') == {'app.kubernetes.io/name': 'prometheus'}
                                      for p in rule['from'])
                if from_prometheus and any(r['port'] in (port['port'], target_port) or str(r['port']) == str(port['port']) for r in rule['ports']):
                    return True
            return False
        assert any(allows(p) for p in policies), f'{namespace}/{service["metadata"]["name"]}:{port_name} not reachable from Prometheus'
    assert {(m['metadata']['namespace'], m['metadata']['name']) for m in monitors} == {('nerdnam', 'api'), ('data', 'postgres-exporter'), ('data', 'redis-exporter')}
    rules = next(x for x in local['observability'] if x['kind'] == 'PrometheusRule')
    assert all(r['labels']['severity'] in ('warning', 'critical') for g in rules['spec']['groups'] for r in g['rules'])
    return len(monitors)


# 9단계 용량 검사. 노드 allocatable 은 배포 전 추정값이다(배포 후 `kubectl describe node` 로 바꿔 확인).
#   EKS AL2023: kube-reserved 메모리 = 255Mi + 11Mi × maxPods, CPU = 6%·1%·0.5%·0.5%(코어 순), eviction 100Mi.
#   maxPods 는 VPC CNI 기본(prefix delegation 없음): m7i.xlarge 58, m7i.large 29.
#   OS 가 보고하는 메모리(MemTotal)는 표기 용량보다 5% 작게 잡는다.
#   2026-10-29 실제 노드 Allocatable: m7i.xlarge 3920m / 14.37Gi / 58 Pod, m7i.large 1930m / 6.94Gi / 29 Pod.
#   이 계산은 app·platform 14.23Gi, data 6.94Gi 로 실측과 같거나 약간 작다(보수적).
NODES = {
    'app': {'instance': 'm7i.xlarge', 'cpu': 4, 'memory_gib': 16, 'max_pods': 58},
    'platform': {'instance': 'm7i.xlarge', 'cpu': 4, 'memory_gib': 16, 'max_pods': 58},
    'data': {'instance': 'm7i.large', 'cpu': 2, 'memory_gib': 8, 'max_pods': 29},
}
# 렌더 결과에 없는 EKS add-on Pod(requests 추정, add-on 기본값 기준). DaemonSet 은 노드마다, 나머지는 taint 가 없는 app 노드에 뜬다.
EKS_DAEMONSETS = {'aws-node': (0.025, 0), 'kube-proxy': (0.1, 0), 'ebs-csi-node': (0.03, 120 * 2**20),
                  'eks-pod-identity-agent': (0.025, 0)}
EKS_APP_NODE_PODS = {'coredns x2': (0.2, 140 * 2**20), 'ebs-csi-controller x2': (0.12, 480 * 2**20)}
# 노드별 requests 합의 상한(allocatable 대비). 교체 중 추가 Pod·JVM·DB 캐시 peak 여유를 남긴다.
REQUEST_HEADROOM = 0.85


def allocatable(node):
    cpu_reserved = sum(rate * min(1, max(0, node['cpu'] - i)) for i, rate in enumerate([0.06, 0.01, 0.005, 0.005]))
    cpu_reserved += 0.0025 * max(0, node['cpu'] - 4)
    memory = node['memory_gib'] * 2**30 * 0.95 - (255 + 11 * node['max_pods'] + 100) * 2**20
    return node['cpu'] - cpu_reserved, memory


def pod_resources(pod):
    """Pod 하나의 requests(cpu, memory)와 memory limit 합. init container 는 가장 큰 것과 비교한다."""
    def total(containers, section, key):
        return sum(quantity(c.get('resources', {}).get(section, {}).get(key, 0)) for c in containers)
    def peak(section, key):
        return max([total(pod['containers'], section, key)] +
                   [quantity(c.get('resources', {}).get(section, {}).get(key, 0)) for c in pod.get('initContainers', [])])
    return peak('requests', 'cpu'), peak('requests', 'memory'), total(pod['containers'], 'limits', 'memory')


def schedulable_nodes(pod):
    selector = pod.get('nodeSelector', {}).get('workload')
    if selector:
        return [selector]
    tolerated = {t.get('value') for t in pod.get('tolerations', []) if t.get('key') == 'dedicated'}
    exists = any(t.get('operator') == 'Exists' and not t.get('key') for t in pod.get('tolerations', []))
    return [n for n in NODES if n == 'app' or exists or n in tolerated]


def check_capacity(local, upstream):
    """역할별 노드에 뜨는 Pod 의 requests·memory limit 합을 allocatable 추정값과 비교한다."""
    usage = {n: {'cpu': 0.0, 'memory': 0.0, 'limit': 0.0, 'pods': []} for n in NODES}
    missing = []

    def add(node, name, cpu, memory, limit):
        usage[node]['cpu'] += cpu
        usage[node]['memory'] += memory
        usage[node]['limit'] += limit
        usage[node]['pods'].append(name)

    for chart, docs in [*local.items(), *upstream.items()]:
        if chart in ('seed', 'root', 'argo-cd', 'sample'):
            continue   # argo-cd 는 bootstrap 이 따로 계산(아래), sample 은 검증용이라 운영에 두지 않는다
        for doc in docs:
            kind = doc['kind']
            if kind in ('Deployment', 'StatefulSet', 'DaemonSet'):
                pod = doc['spec']['template']['spec']
                replicas = 1 if kind == 'DaemonSet' else doc['spec'].get('replicas', 1)
                nodes = schedulable_nodes(pod)
                assert kind == 'DaemonSet' or len(nodes) == 1, f'{chart}/{doc["metadata"]["name"]}: unplaced'
                for node in nodes:
                    cpu, memory, limit = pod_resources(pod)
                    missing.append(f'{chart}/{doc["metadata"]["name"]}') if not (cpu > 0 and memory > 0) else None
                    add(node, f'{chart}/{doc["metadata"]["name"]}', cpu * replicas, memory * replicas, limit * replicas)
            elif kind in ('Prometheus', 'Alertmanager'):
                spec = doc['spec']
                resources = spec.get('resources', {})
                # operator 가 붙이는 config-reloader(기본 10m/50Mi, limit 50Mi)를 더한다
                add(spec['nodeSelector']['workload'], f'{chart}/{kind}',
                    quantity(resources['requests']['cpu']) + 0.01, quantity(resources['requests']['memory']) + 50 * 2**20,
                    quantity(resources['limits']['memory']) + 50 * 2**20)
    for docs in [upstream['argo-cd']]:
        for doc in docs:
            if doc['kind'] in ('Deployment', 'StatefulSet'):
                pod = doc['spec']['template']['spec']
                cpu, memory, limit = pod_resources(pod)
                add(schedulable_nodes(pod)[0], f'argo-cd/{doc["metadata"]["name"]}', cpu, memory, limit)
    assert not missing, f'requests missing (scheduler cannot account for them): {sorted(set(missing))}'
    for node in NODES:
        for name, (cpu, memory) in EKS_DAEMONSETS.items():
            add(node, 'eks/' + name, cpu, memory, 0)
    for name, (cpu, memory) in EKS_APP_NODE_PODS.items():
        add('app', 'eks/' + name, cpu, memory, 0)

    report = []
    for node, spec in NODES.items():
        cpu_alloc, memory_alloc = allocatable(spec)
        used = usage[node]
        assert len(used['pods']) <= spec['max_pods'], f'{node}: too many pods'
        assert used['cpu'] <= cpu_alloc * REQUEST_HEADROOM, f'{node}: CPU requests {used["cpu"]:.2f} > {REQUEST_HEADROOM:.0%} of {cpu_alloc:.2f}'
        assert used['memory'] <= memory_alloc * REQUEST_HEADROOM, \
            f'{node}: memory requests {used["memory"] / 2**30:.2f}Gi > {REQUEST_HEADROOM:.0%} of {memory_alloc / 2**30:.2f}Gi'
        report.append(f'{node} ({spec["instance"]}): pods {len(used["pods"])}/{spec["max_pods"]}, '
                      f'CPU req {used["cpu"]:.2f}/{cpu_alloc:.2f}, mem req {used["memory"] / 2**30:.1f}/{memory_alloc / 2**30:.1f}Gi, '
                      f'mem limit {used["limit"] / 2**30:.1f}Gi')
    # data 노드는 DB·Redis 가 같이 산다. limit 합이 allocatable 을 넘으면 둘이 함께 peak 일 때 노드가 OOM 으로 Pod 를 죽인다.
    assert usage['data']['limit'] <= allocatable(NODES['data'])[1], 'data node memory limits overcommit'
    return report, usage


# 클러스터에서만 나오는 지표(kube-prometheus-stack 의 kubelet·cAdvisor·kube-state-metrics 와 Prometheus 자체).
# 로컬에서 수집할 수 없어 이름을 여기 적는다. 앱·exporter 지표는 tests/fixtures/metrics/*.txt(실제 수집 결과)와 대조한다.
CLUSTER_METRICS = {'up', 'container_memory_working_set_bytes', 'kube_pod_container_status_restarts_total',
                   'kube_pod_container_resource_limits', 'kubelet_volume_stats_used_bytes', 'kubelet_volume_stats_capacity_bytes'}
PROMQL_WORDS = {'by', 'without', 'on', 'ignoring', 'group_left', 'group_right', 'bool', 'and', 'or', 'unless', 'offset', 'inf', 'nan'}


def promql_metrics(expr):
    """PromQL 식에서 지표 이름만 뽑는다(문자열·라벨 조건·범위·함수·by() 라벨 제외)."""
    expr = re.sub(r'"(?:[^"\\]|\\.)*"', '""', expr)
    expr = re.sub(r'\{[^}]*\}', '', expr)
    expr = re.sub(r'\[[^\]]*\]', '', expr)
    expr = re.sub(r'\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)', '', expr)
    names = set()
    for match in re.finditer(r'[a-zA-Z_:][a-zA-Z0-9_:]*', expr):
        rest = expr[match.end():].lstrip()
        word = match.group()
        if rest.startswith('(') or word.lower() in PROMQL_WORDS:
            continue
        if expr[max(0, match.start() - 1)].isdigit():
            continue   # 5m, 1e3 같은 숫자 꼬리
        names.add(word)
    return names


def check_queries(local):
    """알림 규칙·대시보드의 PromQL 이 실제로 있는 지표만 쓰고, 대시보드가 있는 데이터 소스를 가리키는지."""
    known = set(CLUSTER_METRICS)
    for path in (ROOT / 'tests/fixtures/metrics').glob('*.txt'):
        known |= {line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith('#')}
    jobs = {(m['metadata']['namespace'], m['metadata']['name']) for m in local['observability'] if m['kind'] == 'ServiceMonitor'}
    exprs = []
    rules = next(x for x in local['observability'] if x['kind'] == 'PrometheusRule')
    exprs += [(f'rule {r["alert"]}', r['expr']) for g in rules['spec']['groups'] for r in g['rules']]
    dashboards = [x for x in local['observability'] if x['kind'] == 'ConfigMap' and x['metadata'].get('labels', {}).get('grafana_dashboard') == '1']
    uids = set()
    for config in dashboards:
        assert config['metadata']['namespace'] == 'monitoring'
        (text,) = config['data'].values()
        board = json.loads(text)
        assert board['uid'] not in uids and board['editable'] is False, board['uid']
        uids.add(board['uid'])
        ids = [p['id'] for p in board['panels']]
        assert len(ids) == len(set(ids)), f'{board["uid"]}: duplicate panel id'
        for panel in board['panels']:
            for target in panel.get('targets', []):
                source = target['datasource']
                assert source == panel['datasource'] and source['uid'] in ('prometheus', 'loki', 'tempo'), f'{board["uid"]}: {panel["title"]}'
                if source['type'] == 'prometheus':
                    exprs.append((f'{board["uid"]}: {panel["title"]}', target['expr']))
    for name, expr in exprs:
        unknown = promql_metrics(expr) - known
        assert not unknown, f'{name}: unknown metrics {sorted(unknown)} (not in tests/fixtures/metrics or CLUSTER_METRICS)'
        # job 라벨은 ServiceMonitor 이름(= Service 이름)이다. namespace 와 짝이 맞아야 한다.
        for namespace, job in re.findall(r'namespace="([^"]+)",\s*job="([^"]+)"', expr):
            if namespace != 'monitoring':
                assert (namespace, job) in jobs, f'{name}: no ServiceMonitor {namespace}/{job}'
    return len(dashboards), len(exprs)


def quantity(value):
    """Kubernetes CPU/메모리 수량을 숫자(코어 또는 바이트)로 바꾼다."""
    value = str(value)
    units = {'Ki': 2**10, 'Mi': 2**20, 'Gi': 2**30, 'Ti': 2**40, 'm': 1e-3}
    for unit, factor in units.items():
        if value.endswith(unit):
            return float(value[:-len(unit)]) * factor
    return float(value)


def check_data_layer(local):
    docs = local['data']
    by_kind = {}
    for doc in docs:
        by_kind.setdefault(doc['kind'], []).append(doc)
    root_apps = {x['metadata']['name']: x for x in local['root'] if x['kind'] == 'Application'}
    assert root_apps['nerdnam-data']['spec']['source']['path'] == 'gitops/data'
    assert 'automated' not in root_apps['nerdnam-data']['spec'].get('syncPolicy', {})

    services = {x['metadata']['name']: x for x in by_kind['Service']}
    assert all(x['metadata']['namespace'] == 'data' for x in services.values())
    assert all(x['spec'].get('type', 'ClusterIP') == 'ClusterIP' for x in services.values()), 'data must stay internal'

    sets = {x['metadata']['name']: x for x in by_kind['StatefulSet']}
    assert set(sets) == {'postgres', 'redis'}
    ports = {'postgres': 5432, 'redis': 6379}
    requests = {'cpu': 0.0, 'memory': 0.0}
    limits = 0.0
    storage = 0.0
    used_keys = set()
    for name, sts in sets.items():
        spec = sts['spec']
        pod = spec['template']['spec']
        where = f'data/{name}'
        assert sts['metadata']['namespace'] == 'data'
        assert spec['replicas'] == 1, where
        assert 'Delete=false' in sts['metadata']['annotations']['argocd.argoproj.io/sync-options'], where
        assert spec['persistentVolumeClaimRetentionPolicy'] == {'whenDeleted': 'Retain', 'whenScaled': 'Retain'}, where
        headless = services[spec['serviceName']]
        assert headless['spec']['clusterIP'] == 'None', where
        client = services[name]
        assert client['spec']['selector'] == spec['selector']['matchLabels'] == {'app': name}, where
        assert client['spec']['ports'][0]['port'] == ports[name], where
        assert pod['nodeSelector'] == {'workload': 'data'}, where
        assert any(t.get('key') == 'dedicated' and t.get('value') == 'data' and t.get('effect') == 'NoSchedule'
                   for t in pod['tolerations']), where
        assert pod['automountServiceAccountToken'] is False and pod['enableServiceLinks'] is False, where
        assert pod['securityContext']['runAsNonRoot'] is True and pod['securityContext']['fsGroup'], where
        claims = spec['volumeClaimTemplates']
        assert len(claims) == 1 and claims[0]['spec']['storageClassName'] == 'gp3-retain', where
        assert claims[0]['spec']['accessModes'] == ['ReadWriteOnce'], where
        storage += quantity(claims[0]['spec']['resources']['requests']['storage'])
        persistent = {v['name'] for v in pod['volumes'] if 'emptyDir' in v or 'configMap' in v}
        assert claims[0]['metadata']['name'] not in persistent, f'{where}: data must live on the PVC'
        (container,) = pod['containers']
        assert '@sha256:' in container['image'], f'{where}: image must be pinned by digest'
        security = container['securityContext']
        assert security['readOnlyRootFilesystem'] is True and security['allowPrivilegeEscalation'] is False, where
        assert security['capabilities']['drop'] == ['ALL'], where
        for probe in ['startupProbe', 'readinessProbe', 'livenessProbe']:
            assert 'exec' in container[probe], f'{where}: {probe}'
        resources = container['resources']
        assert 'cpu' not in resources.get('limits', {}), f'{where}: CPU limit causes throttling of the database'
        requests['cpu'] += quantity(resources['requests']['cpu'])
        requests['memory'] += quantity(resources['requests']['memory'])
        limits += quantity(resources['limits']['memory'])
        assert quantity(resources['requests']['memory']) <= quantity(resources['limits']['memory']), where
        for env in container['env']:
            ref = env.get('valueFrom', {}).get('secretKeyRef')
            if ref:
                assert ref['name'] == 'data-secrets', where
                used_keys.add(ref['key'])
        mounts = {m['mountPath'] for m in container['volumeMounts']}
        assert {'/tmp'} <= mounts, where
    for exporter in by_kind['Deployment']:
        pod = exporter['spec']['template']['spec']
        (container,) = pod['containers']
        where = f"data/{exporter['metadata']['name']}"
        assert exporter['metadata']['name'] in ('postgres-exporter', 'redis-exporter'), where
        assert '@sha256:' in container['image'] and pod['nodeSelector'] == {'workload': 'data'}, where
        assert pod['securityContext']['runAsNonRoot'] and isinstance(pod['securityContext']['runAsUser'], int), where
        assert container['securityContext']['readOnlyRootFilesystem'] is True, where
        for env in container['env']:
            ref = env.get('valueFrom', {}).get('secretKeyRef')
            if ref:
                used_keys.add(ref['key'])
                assert ref['key'].endswith('-exporter-password'), f'{where}: exporters use their own accounts only'
    assert used_keys == DATA_SECRET_KEYS, f'data secret keys drifted: {sorted(used_keys ^ DATA_SECRET_KEYS)}'
    pg_env = {e['name']: e.get('value') for e in sets['postgres']['spec']['template']['spec']['containers'][0]['env']}
    assert pg_env['PGDATA'].startswith('/var/lib/postgresql/data/'), 'PGDATA must be below the EBS mount root'
    assert 'scram-sha-256' in pg_env['POSTGRES_INITDB_ARGS'] and 'POSTGRES_HOST_AUTH_METHOD' not in pg_env

    quota = by_kind['ResourceQuota'][0]['spec']['hard']
    assert quota['services.loadbalancers'] == '0' and quota['services.nodeports'] == '0'
    assert requests['cpu'] <= quantity(quota['requests.cpu'])
    assert requests['memory'] <= quantity(quota['requests.memory'])
    assert limits <= quantity(quota['limits.memory'])
    assert storage <= quantity(quota['requests.storage'])
    assert by_kind['LimitRange'][0]['metadata']['namespace'] == 'data'

    # BE 가 받는 키는 data 비밀값에서만 오고, 슈퍼유저 비밀번호는 nerdnam namespace 로 가지 않는다.
    secrets = {x['metadata']['name']: x for x in local['secrets']}
    backend = secrets['backend-secrets']['spec']
    data_arn = secrets['data-secrets']['spec']['dataFrom'][0]['extract']['key']
    mapped = {x['secretKey']: x['remoteRef']['property'] for x in backend['data']}
    assert mapped == BACKEND_FROM_DATA
    assert all(x['remoteRef']['key'] == data_arn for x in backend['data'])
    assert 'postgres-superuser-password' not in mapped.values()

    # 양쪽 namespace 정책: data ingress 와 nerdnam egress 가 같은 Pod/포트를 가리켜야 한다.
    policies = {(x['metadata']['namespace'], x['metadata']['name']): x for x in by_kind['NetworkPolicy']}
    egress = policies[('nerdnam', 'allow-api-to-data')]['spec']
    api_labels = egress['podSelector']['matchLabels']
    assert egress['policyTypes'] == ['Egress']
    allowed_out = {(r['to'][0]['podSelector']['matchLabels']['app'], r['ports'][0]['port']) for r in egress['egress']}
    assert all(r['to'][0]['namespaceSelector']['matchLabels'] == {'kubernetes.io/metadata.name': 'data'} for r in egress['egress'])
    assert allowed_out == set(ports.items())
    for name, port in ports.items():
        policy = policies[('data', f'allow-api-to-{name}')]['spec']
        assert policy['podSelector']['matchLabels'] == {'app': name}
        assert policy['policyTypes'] == ['Ingress']
        (rule,) = policy['ingress']
        (peer,) = rule['from']
        assert peer['namespaceSelector']['matchLabels'] == {'kubernetes.io/metadata.name': 'nerdnam'}
        assert peer['podSelector']['matchLabels'] == api_labels, 'only BE pods may reach the data layer'
        assert rule['ports'] == [{'protocol': 'TCP', 'port': port}]
    assert not any(x['spec'].get('ingress') == [{}] or x['spec'].get('egress') == [{}] for x in by_kind['NetworkPolicy'])
    return len(sets)


if __name__ == '__main__':
    main()
