# Vendored model samples

Source copies of maas-billing `docs/samples/maas-system/free` and `premium`.

Kustomize applies the same YAML from `kustomize/client/models/` (kustomize security rules forbid referencing paths outside that directory). After editing here, re-copy:

```bash
cp samples/free/llm-inferenceservice.yaml kustomize/client/models/free-llm-inferenceservice.yaml
cp samples/free/maas-resources.yaml kustomize/client/models/free-maas-resources.yaml
cp samples/premium/llm-inferenceservice.yaml kustomize/client/models/premium-llm-inferenceservice.yaml
cp samples/premium/maas-resources.yaml kustomize/client/models/premium-maas-resources.yaml
```
