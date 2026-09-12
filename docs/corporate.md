# Office integration (AD, OWA, Skype for Business)

The office runs Active Directory, on-prem Exchange with OWA, and Skype for
Business Server. The machine stays a local-user workstation (no domain join);
a Kerberos ticket gives single sign-on to everything that speaks Negotiate.

Set in `config/build.env` before building (all optional):

| Variable | Example | Used for |
|---|---|---|
| `AD_REALM` | `CORP.EXAMPLE.COM` | `/etc/krb5.conf` default realm |
| `AD_DOMAIN` | `corp.example.com` | Chrome SSO allow-list `*.corp.example.com` |
| `AD_KDC` | `dc1.corp.example.com dc2.corp.example.com` | KDCs when there are no DNS SRV records |
| `OWA_URL` | `https://mail.corp.example.com/owa` | `Super+m` / `lite-owa` |
| `EXTRA_HOSTS` | `10.1.1.5 dc1.corp.example.com dc1\|10.1.1.20 mail.corp.example.com` | `/etc/hosts` when there is no DNS |

The office CA in `config/ca/*.crt` is trusted system-wide, so HTTPS to OWA,
Exchange and the SfB front end validates.

## Daily use

```bash
lite-login            # kinit $USER@AD_REALM, asks for the AD password
klist                 # shows the ticket (10 h, renewable 7 days)
```

* **Email**: `Super+m` opens OWA as an app window in Chrome. With a ticket and
  OWA configured for Windows authentication there is no login page; otherwise
  OWA's forms login works as usual.
* **Intranet / SharePoint**: Chrome sends Negotiate (Kerberos) or NTLM to any
  host under `AD_DOMAIN` automatically (policy in
  `/etc/opt/chrome/policies/managed/lite-sso.json`).
* **Skype for Business chat**: `Super+s` starts Pidgin. First time: Accounts >
  Add, Protocol "Office Communicator" (SIPE):
  * Username: `you@corp.example.com` (your SIP address)
  * Login: `CORP\you`
  * Password: leave empty when using Kerberos, otherwise your AD password
  * Advanced tab: Authentication scheme `Kerberos` (ticket from `lite-login`)
    or `NTLM`; Server, if auto-discovery fails: `sfb-fe.corp.example.com:5061`
    with `TLS`.
  Chat, presence, contact search and group chats work. Audio and video calls
  do not (no Linux client for SfB). Use the SfB Web App in Chrome for meetings
  with IM only.
* **Thunderbird** (optional, in `pool/extra` for Nexus): `sudo apt install
  thunderbird`, add the account with Exchange (EWS) and the OWA host name if
  you prefer a desktop mail client over OWA.

## Notes

* Nothing here requires domain join. If IT later wants managed logins, add
  `sssd realmd adcli` to `config/packages/corporate.txt` and run `realm join`
  after install.
* Passwords are never stored in the image. Kerberos credentials live in the
  kernel keyring and vanish at reboot.
