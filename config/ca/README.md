Drop the office internal CA certificate(s) here as `*.crt` (PEM).
They are installed into the image's system trust store so apt, docker and
curl trust the Nexus HTTPS endpoint. Example: `config/ca/office-root-ca.crt`.
