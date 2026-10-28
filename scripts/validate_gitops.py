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
    print(f'PASS: apps ({app_count} Deployments): digest-pinned ECR images, placement, pod security, probes, '
          'public routes, Bedrock identity and namespace traffic policies')



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
    # Git 의 images.yaml 만으로는(CI 가 digest 를 채우기 전) 렌더링이 실패해야 한다: 가짜 이미지 기본값 금지.
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
                else:
                    target = peer['podSelector']['matchLabels']['app']
                for port in rule_['ports']:
                    egress_to.setdefault(source, set()).add((target, port['port']))
    assert egress_to == {'web': {('api', ports['api'])},
                         'api': {('ai', ports['ai']), ('0.0.0.0/0', 443)},
                         'ai': {('169.254.170.23/32', 80), ('0.0.0.0/0', 443)}}
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
    assert not any(x['kind'] in ('Ingress',) for docs in [stack, upstream['loki'], upstream['alloy']] for x in docs)

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
