# Security Policy

Braid handles private conversations, encryption keys and credentials for
your own infrastructure — security reports are taken seriously and answered
quickly.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Email **eric@bostrot.com** with:

- what you found and where (file, screen, or protocol flow),
- steps to reproduce or a proof of concept,
- what an attacker gains.

You will get an acknowledgement within a few days. Once fixed, you are
welcome to disclose — credit is yours, coordinated disclosure appreciated.

## Scope

Particularly interesting:

- anything that leaks message plaintext, keys or tokens off the device
  (the app must only ever talk to servers the user configured),
- E2EE correctness: verification, cross-signing, key backup,
- the embedded MCP server's authentication and scoping,
- secrets handling in `weft_store` (keychain / keystore usage),
- notification content leaking through system surfaces it shouldn't.

Out of scope: vulnerabilities in your homeserver, bridges, or the upstream
Matrix SDK (report those upstream — but a heads-up is still welcome), and
attacks requiring a rooted/jailbroken device or physical access.

## Supported versions

The latest release and `main`. There are no security backports to older
versions.
