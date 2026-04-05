# Private Local Files

Keep private operator-only files here.

Tracked files in this repo must stay public-safe. Do not commit:
- SSH inventory
- Tailscale hostnames
- private fleet topology
- wallet secrets
- live runtime data

The current Zend control-plane integration expects the live Contabo inventory at
`private/contabo-fleet.json`.
