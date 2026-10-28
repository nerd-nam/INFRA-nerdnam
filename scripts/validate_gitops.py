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
    for name in ['seed', 'root', 'foundation', 'secrets', 'sample']:
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
    rejected = subprocess.run([args.helm, 'template', 'missing-values', str(ROOT / 'gitops/root')],
                              capture_output=True, text=True)
    assert rejected.returncode != 0
    print(f'PASS: 5 local charts, 5 pinned upstream charts, {custom_count} custom resources, {scheduled} scheduling checks')
    print('PASS: NLB/TLS, secret boundaries, storage retention and missing-input checks')


if __name__ == '__main__':
    main()
