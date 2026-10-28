#!/usr/bin/env python3
"""Offline Helm rendering, CRD schema and repository-specific contract checks.

No kubectl or AWS mutation is executed. --fetch downloads pinned public charts
into a cache, verifies their digests, then uses the same checks as offline mode.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urljoin

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parents[1]
LOCAL_CHARTS = ['seed', 'root', 'foundation', 'secrets', 'data', 'sample']
# Secrets Manager nerdnam/dev/data JSON 키 계약 (docs/데이터-계층-작업계획.md)
DATA_SECRET_KEYS = {'postgres-superuser-password', 'postgres-migrator-password', 'postgres-app-password', 'redis-api-password'}
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

    def render(name, chart, namespace, values):
        raw = run([args.helm, 'template', name, str(chart), '--namespace', namespace,
                   '--kube-version', '1.35.0', '--include-crds', '-f', str(values)])
        docs = [x for x in yaml.safe_load_all(raw) if x]
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

    local = {}
    for name in LOCAL_CHARTS:
        chart = ROOT / 'gitops' / name
        run([args.helm, 'lint', str(chart), '--strict', '--kube-version', '1.35.0', '-f', str(fixture)])
        local[name] = render('nerdnam-' + name, chart, 'argocd' if name in ['seed', 'root'] else 'nerdnam', fixture)

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
    for docs in local.values():
        for doc in docs:
            group = doc['apiVersion'].split('/')[0]
            if group in ['argoproj.io', 'cert-manager.io', 'external-secrets.io']:
                schema = schemas[(doc['apiVersion'], doc['kind'])]
                jsonschema.Draft7Validator(schema).validate(doc)
                custom_count += 1
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
            assert pod.get('nodeSelector', {}).get('workload') == expected, f'{chart}/{doc["metadata"]["name"]}: placement'
            if expected == 'platform':
                assert any(t.get('key') == 'dedicated' and t.get('value') == 'platform' and t.get('effect') == 'NoSchedule'
                           for t in pod.get('tolerations', [])), f'{chart}: missing toleration'
            scheduled += 1

    by_kind = {doc['kind']: doc for doc in local['sample']}
    assert by_kind['Ingress']['spec']['tls'][0]['secretName'] == by_kind['Certificate']['spec']['secretName']
    assert by_kind['Ingress']['spec']['rules'][0]['host'] == by_kind['Certificate']['spec']['dnsNames'][0]
    assert by_kind['Service']['spec'].get('type', 'ClusterIP') == 'ClusterIP'
    storage = next(x for x in local['foundation'] if x['kind'] == 'StorageClass')
    assert storage['reclaimPolicy'] == 'Retain' and storage['volumeBindingMode'] == 'WaitForFirstConsumer'
    assert storage['parameters']['encrypted'] == 'true'
    store = next(x for x in local['foundation'] if x['kind'] == 'ClusterSecretStore')
    assert 'auth' not in store['spec']['provider']['aws'], 'Pod Identity uses ambient credentials'
    assert store['spec']['conditions'][0]['namespaces'] == ['nerdnam', 'data']
    assert all(x['spec']['target']['deletionPolicy'] == 'Retain' for x in local['secrets'])

    # Missing environment values must fail; example fixtures must not become defaults.
    data_count = check_data_layer(local)

    rejected = subprocess.run([args.helm, 'template', 'missing-values', str(ROOT / 'gitops/root')],
                              capture_output=True, text=True)
    assert rejected.returncode != 0
    print(f'PASS: {len(LOCAL_CHARTS)} local charts, {len(lock)} pinned upstream charts, '
          f'{custom_count} custom resources, {scheduled} scheduling checks')
    print('PASS: NLB/TLS, secret boundaries, storage retention and missing-input checks')
    print(f'PASS: data layer ({data_count} StatefulSets): placement, PVC retention, pinned images, '
          'pod security, probes, secret keys, quota and BE<->data network policies')



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
