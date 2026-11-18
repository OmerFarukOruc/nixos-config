# Home network

How the home line reaches Discord and NextDNS: the router's DPI bypass and DNS,
the NextDNS profile every device shares, and the Windows PC. Read it before you
change DNS, NextDNS, zapret2 or anything on the router, or when Discord or a
site stops working at home.

A date in this guide marks a measurement or a reading of a setting on that day.

- [Layout](#layout)
- [Diagnose](#diagnose)
- [Router](#router)
- [Router bypass](#router-bypass)
- [Router DNS](#router-dns)
- [NextDNS profile](#nextdns-profile)
- [Windows PC](#windows-pc)
- [Decisions](#decisions)

## Layout

The line is Türk Telekom PPPoE (`ppp1` on the router, a CGNAT address, IPv4
only in practice). Its DPI resets TLS connections to Discord by SNI, and its
plain DNS answers `discord.com` with a block page (`195.175.254.2`).

```
LAN device ──► router ── nfqws2 bypass on ppp1 ──► ISP ──► Discord
   │              └── DNS proxy ── DoT/DoH ──► NextDNS (one profile)
   │
nixos-rog, nixos-desktop: own zapret2 on their uplink, DoT to NextDNS
Windows PC:               DoH to NextDNS, its own winws2 bypass stopped
```

Every LAN device goes through the router's bypass. The NixOS hosts' own
zapret2 is in [DPI bypass](architecture.md#dpi-bypass).

## Diagnose

Work through the steps in order; a step is done when its expected output shows.

1. DNS reaches NextDNS. From the device, open
   `https://x<random>.test.nextdns.io/` in a browser or with curl. Expect
   `"status": "ok"`, with `"protocol": "DOT"` from a NixOS host, `"DOH"` from
   the Windows PC, and `"DOT"` or `"DOH"` from a device that uses the router's
   DNS. `"status": "unconfigured"` means the device left NextDNS. Never paste
   the output anywhere public: it holds the public IP.
2. The router bypass runs: `/opt/etc/init.d/S51nfqws2 status` on the router.
3. Discord connects through the router. Test from a client with no bypass of
   its own: the Windows PC with `winws2` stopped, or a NixOS host with its own
   bypass stopped for the test. A NixOS host with `nfqws2@default` running
   passes without the router too, so it proves nothing about the router.

   ```sh
   sudo systemctl stop nfqws2@default
   for h in discord.com gateway.discord.gg cdn.discordapp.com discord.gg updates.discord.com; do
     printf '%-24s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code} %{errormsg}' --max-time 6 "https://$h")"
   done
   sudo systemctl start nfqws2@default && systemctl is-active nfqws2@default
   ```

   Any code but `000` passes; 403 and 404 are normal. `000 ... Connection reset`
   is the ISP block. Run the loop several times, because a strategy that works
   only in part fails some runs. The step is done when the last command prints
   `active`. curl with OpenSSL 3.5 sends a post-quantum key share, which makes
   the ClientHello as large as a browser's; `--curves X25519` gives the small
   one. A strategy can pass one size and fail the other.
4. Match the symptom:

| Symptom | Likely cause | Go to |
|---|---|---|
| Discord hosts reset on every device | router bypass stopped, or the ISP changed its DPI | [Router bypass](#router-bypass) |
| Discord hosts resolve to `195.175.254.2` or time out | DNS left NextDNS, or a device cached the block page | [Router DNS](#router-dns) |
| Text works, voice does not connect | voice rule no longer effective | [Router bypass](#router-bypass) |
| A name resolves to `0.0.0.0` on every device | a NextDNS list blocks it; Logs shows the blocked query | [NextDNS profile](#nextdns-profile) |
| A name resolves, but TLS fails or resets on every device | the router's auto-list treats a healthy host | [Router bypass](#router-bypass) |
| `test.nextdns.io` passes, but a browser shows "no profile" | the browser resolves names itself | [Windows PC](#windows-pc) |
| A site breaks only on a NixOS host | zapret2's auto-list on that host | [DPI bypass](architecture.md#dpi-bypass) |
| A game refuses to start on the Windows PC | WinDivert loaded | [Windows PC](#windows-pc) |

## Router

Keenetic Hopper DSL (KN-3610), KeeneticOS 5.1.8, EN7516 dual-core 900 MHz
(Entware architecture `mips`), 256 MB RAM, with Entware on its internal
storage. Its address is the default gateway (`ip route show default`), written
`<router-ip>` below. The web panel is `http://<router-ip>`, its command line is
`http://<router-ip>/a`.

Entware's SSH server (dropbear) listens on port 222 for `root`. Agents use the
key `C:\Users\Oruc\.ssh\keenetic_entware` on the Windows PC; nixos-rog's
`~/.ssh` and `/root/.ssh` held no router key on 2026-11-18.

```
ssh -i C:\Users\Oruc\.ssh\keenetic_entware -p 222 -o BatchMode=yes -o IdentitiesOnly=yes root@<router-ip>
```

The public key is in `/opt/etc/dropbear/authorized_keys`, with a copy in
`/opt/root/.ssh/authorized_keys`. Agents never type the router's passwords:
Omer logs in, and an agent reads pages or puts a command in the web command
line for him to send. `show running-config` prints the PPPoE login and the
NextDNS account token, so filter it with `grep` or `sed` and never copy it.

Without a router key, an agent on a NixOS host still sees which profile and
protocol the router's DNS uses:

```sh
h="x$(date +%s%N).test.nextdns.io"
ip=$(nix shell nixpkgs#knot-dns -c kdig +short @<router-ip> "$h" A | tail -1)
curl -s --resolve "$h:443:$ip" "https://$h/" | grep -oE '"(status|protocol|profile)": *"[^"]*"'
```

On 2026-11-18, before and after a router reboot, this printed
`"protocol": "DOH"` and the same `"profile"` fingerprint as a query from
nixos-rog.

## Router bypass

`nfqws2-keenetic` 1.3.3 (nfqws2 1.0.7) from its opkg feed.

| Path | Purpose |
|---|---|
| `/opt/etc/nfqws2/nfqws2.conf` | live config (`.orig` beside it is the package default) |
| `/opt/etc/nfqws2/lists/user.list` | always-treated domains (Discord) |
| `/opt/etc/nfqws2/lists/auto.list` | domains nfqws2 added itself |
| `/opt/etc/nfqws2/lists/exclude.list` | never treated, even when on another list |
| `/opt/var/log/nfqws2.log` | auto-list decisions |
| `/opt/etc/init.d/S51nfqws2` | `start`, `stop`, `restart`, `reload`, `status` |

Master copies of the config and lists are on the Windows PC in
`C:\zapret\user\router\`; only that PC holds them.

In force:

- Interface `ppp1`, IPv4 only, `MODE_AUTO`.
- TCP 443, TLS only: `--payload=tls_client_hello --lua-desync=multidisorder:pos=2:seqovl=1`.
- QUIC off (`NFQWS_ARGS_QUIC=""`, 443 not in `UDP_PORTS`). QUIC to Discord is
  not blocked on this line.
- Discord voice on UDP `19294-19344,50000-50099`:
  `--filter-l7=stun,discord --payload=stun,discord_ip_discovery --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2`.
  Discord voice stayed up through the router while Call of Duty ran on the
  Windows PC (Omer, 2026-11-18).
- IP-list profiles off (`NFQWS_ARGS_IPSET=""`).
- The package's iptables rules queue the first 15 packets of each connection
  in both directions, so the auto-list sees replies.
- No Keenetic access policy named `nfqws` exists, so every LAN device is
  processed. To limit it, create that policy in the router UI and put devices
  in it.
- The package default is Russia-oriented: YouTube and Google lists, rotating
  strategies, and a UDP rule on ports 49152-65535 that would touch game
  traffic. Do not restore it blindly.

Operations, over SSH:

```
/opt/etc/init.d/S51nfqws2 status
/opt/etc/init.d/S51nfqws2 restart
cat /opt/etc/nfqws2/lists/auto.list
tail -30 /opt/var/log/nfqws2.log
opkg update && opkg upgrade nfqws2-keenetic
```

Lists:

- A site broke after the auto-list added it: delete its line from `auto.list`
  and add the domain to `exclude.list`.
- Force a site to be treated: add it to `user.list`.
- Keep Microsoft domains excluded; they break when treated. `com.tr`,
  `gov.tr` and `edu.tr` are excluded as whole zones, so unblocking one
  `.com.tr` site needs the `com.tr` line replaced by specific domains.
- The strategy is tuned for Discord. An auto-added site that needs another
  strategy needs its own profile with its own list.

To try another strategy, edit `NFQWS_ARGS`, `restart`, and repeat step 3 of
[Diagnose](#diagnose). The PC's repeat-tester starts `winws2` locally, so it
cannot score a router strategy. It scored these on the Windows PC, on this
line, on 2026-11-18:

| Strategy | Small ClientHello | Large ClientHello |
|---|---|---|
| `multidisorder:pos=2:seqovl=1` (in use) | 36/36 | 36/36 |
| `fake:blob=fake_default_tls:tcp_md5:repeats=1` (the NixOS hosts) | 36/36 | 36/36 |
| `fake:blob=0x00000000:tcp_md5:repeats=1` | 36/36 | 36/36 |
| `fake ... tcp_md5` + `multidisorder:pos=1,midsld` | 36/36 | 36/36 |
| `hostfakesplit:tcp_md5:repeats=1` | 24/24 | 24/24 |
| `fakedsplit:pos=midsld:tcp_md5` | 24/24 | 24/24 |
| `multisplit:pos=1` and other split-only or disorder-only variants | 9 to 14 of 24 | 24/24 |

Split-only strategies pass the scanner, which uses the large ClientHello, and
fail about half the time for the small one. The strategy in use is also the
Türk Telekom preset of `cagritaskn/SplitWire-Turkey` (`presets2.txt`) and
`alimali54/zapret-win-turkey`.

Voice has no automated test: join a voice channel. When voice fails while text
works, compare the voice rule with the last profile of upstream
`preset2_example.cmd` in `bol-van/zapret-win-bundle`, or try `repeats=6`.

Install facts: the router already had OPKG, Netfilter modules, Xtables-addons,
Traffic Control and the SSH server. Entware's `opkg` fetched its HTTPS feed only
after the busybox `wget` link at `/opt/usr/bin/wget`, which shadowed
`/opt/bin/wget` (wget-ssl), was removed. To remove Entware, run `no opkg disk`,
`no system mount storage:` and `erase storage:` in the web command line.
Verified after a router reboot (2026-11-18, reported by Omer; router uptime
and `S51nfqws2 status` were not read): from nixos-rog with its own bypass
stopped, requests to `discord.com`, `gateway.discord.gg` and
`cdn.discordapp.com` passed in 3 rounds (9 of 9), so the router bypass ran
without a manual start.

## Router DNS

The router's DNS proxy forwards to NextDNS (running and startup config):

```
dns-proxy
    tls upstream 45.90.28.0 853 sni <profile-id>.dns.nextdns.io
    tls upstream 45.90.30.0 853 sni <profile-id>.dns.nextdns.io
    https upstream https://dns.nextdns.io/<profile-id> dnsm
```

With encrypted upstreams present, KeeneticOS stops using the ISP's servers.
Keenetic's built-in NextDNS component is linked and assigned to the Home
segment with its content filter off; do not turn it on over these upstreams
without testing.

Check, over SSH: `ndmc -c "show dns-proxy" | grep dns_server` lists forwarders
on `127.0.0.1:405xx`, and `nslookup discord.com 127.0.0.1` returns
`162.159.x.x`. Undo with `ndmc -c "no dns-proxy tls upstream 45.90.28.0 853"`,
the same for `45.90.30.0` and for the `https` upstream, then
`ndmc -c "system configuration save"`.

A device can keep the block-page address cached after a DNS change: turn its
Wi-Fi off and on, then reopen the app. To find a device on the router,
`ip neigh show dev br0` and `ndmc -c "show ip hotspot"`; iPhones use a private
MAC and may have no host name.

## NextDNS profile

One profile serves every device: the router, the Windows PC and both NixOS
hosts. Its ID is the sops secret `nextdns-profile`
(`/run/secrets/nextdns-profile` on nixos-rog and nixos-desktop); compare
against it with `sudo grep -q`, never print it, and write `<profile-id>` in
this repository. The dashboard is `https://my.nextdns.io/<profile-id>/` and
needs Omer's login, which his Brave and a PC's box browser hold and devbox's box browser does not.

NextDNS names a device by the part of the DoT server name before the profile
ID, so nixos-rog and nixos-desktop appear by host name
(`nixosModules/nextdns.nix`). Devices behind the router share its upstreams,
so NextDNS cannot tell them apart.

Settings, read from the dashboard on 2026-11-18. Every setting not named here
was off.

| Tab | On |
|---|---|
| Security | Threat Intelligence Feeds, Dynamic DNS Hostnames, DNS Payload Delivery, Local Network Addresses, Decentralized Web Gateways, Parked Domains, Child Sexual Abuse Material |
| Privacy | blocklist HaGeZi Multi PRO (the only list), Block Rotating Ad Domains, Allow Tracking Links |
| Parental Control | nothing |
| Denylist | empty |
| Settings | Logs (1 day, Switzerland, domains logged, client IPs not logged), Anonymized EDNS Client Subnet, Cache Boost, Bypass Age Verification |

Why some stay off:

- Algorithmically Generated Domains: Discord's voice server names look
  random, such as `c-otp01-01124a0c` in Vesktop's voice details on 2026-11-18.
- Tunneling Endpoints: `yokoffing/NextDNS-Config` warns that it breaks remote
  home access and hosting; nothing tested it here.
- Newly Registered Domains, High-Risk TLDs and TLD blocks: the same guide
  advises against them for a setup nobody watches.
- Native Tracking: HaGeZi's tiers already carry the native trackers that break
  nothing (HaGeZi README, Native Tracker), and the guide's Windows and Xbox
  allowlist entries exist because that list blocks them.

The Allowlist holds 23 domains:

```
risoluto.dev  statuslantern.com  sentry.io  web.plaud.ai  nextdns.io
graph.facebook.com  graph.instagram.com  i.instagram.com  b-graph.facebook.com
connect.facebook.com  connect.facebook.net  graph-fallback.facebook.com
z-m-graph.facebook.com  graph-fallback.instagram.com
xp.apple.com  smoot.apple.com  amp-api-edge.apps.apple.com  amp-api-search-edge.apps.apple.com
settings-win.data.microsoft.com  v10.events.data.microsoft.com  v20.events.data.microsoft.com
s.youtube.com  js.media-lab.ai
```

`risoluto.dev` and `statuslantern.com` stay because the rebinding protection
(Local Network Addresses) answers their Tailscale addresses with `0.0.0.0`
([DNS](nixos-rog.md#dns)). `sentry.io` and `web.plaud.ai` are there because
HaGeZi Multi PRO blocks them and Omer uses both. The rest come from
`yokoffing/NextDNS-Config`'s Allowlist section.

The HaGeZi wildcard lists of 2026-11-18
(`https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/<tier>.txt`)
contained none of `discord.com`, `discord.gg`, `discord.media`,
`discordapp.com`, `discordapp.net`, the Steam, Call of Duty and Battle.net
domains, `api.anthropic.com`, `chatgpt.com`, `github.com` or
`tailscale.com` in any tier up to PRO++; `ultimate.txt` lists
`log.tailscale.io`. A domain is in a list when it, or a parent domain, has a
`*.<domain>` line.

When a name resolves to `0.0.0.0` on every device, open the Logs tab, find the
blocked query within the day, and add the domain to the Allowlist. On nixos-rog,
`scripts/verify-nixos-rog.sh` fails its `discord-com-resolves`,
`gateway-discord-gg-resolves` or `cdn-discordapp-com-resolves` check when a
list blocks Discord.

## Windows PC

Windows 11 Pro (ReviOS build), Secure Boot on. Do not turn off Secure Boot or
change other security settings without asking Omer. The PC's own playbook,
`C:\Users\Oruc\Documents\zapret-PLAYBOOK.md`, and `C:\zapret` exist only on
that PC.

DNS is NextDNS over native Windows DoH on the `Ethernet` and `Wi-Fi` adapters,
fallback to plain DNS off. The IPv6 servers carry the profile ID: `2a07:a8c0::`
and `2a07:a8c1::`, each followed by `<p1>:<p2>`, the ID's first two characters
and its last four. To re-apply after a network reset, in an elevated
PowerShell:

```powershell
$tpl = 'https://dns.nextdns.io/<profile-id>'
$v4 = '45.90.28.0','45.90.30.0'; $v6 = '2a07:a8c0::<p1>:<p2>','2a07:a8c1::<p1>:<p2>'
foreach ($ip in $v4 + $v6) { if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) { Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $tpl -AllowFallbackToUdp $false -AutoUpgrade $true } }
foreach ($a in 'Ethernet','Wi-Fi') { Set-DnsClientServerAddress -InterfaceAlias $a -ServerAddresses ($v4 + $v6) }
Clear-DnsClientCache
```

If NextDNS is down, DNS fails, because fallback is off; set the adapter to
`1.1.1.1` or `9.9.9.9` for a while.

A Chromium browser on Windows (Brave, Opera) in secure-DNS mode "automatic"
sees the NextDNS server addresses and switches to NextDNS's generic DoH
endpoint, which carries no profile; `my.nextdns.io` then shows "no profile".
Turning secure DNS off sends plain UDP queries past Windows DoH. Set each
browser's secure DNS to Custom, `https://dns.nextdns.io/<profile-id>`, and set
it again in a new browser profile. On nixos-rog, Brave left on "OS default"
sees only the local resolver `127.0.0.53` and reported `"protocol": "DOT"` on
`test.nextdns.io` on 2026-11-18.

The PC's own bypass, zapret2 `winws2` from `bol-van/zapret-win-bundle` in
`C:\zapret`, is installed, stopped and set to Manual. Call of Duty (Ricochet
anti-cheat) exits 6 to 16 s after start while the WinDivert driver is loaded,
which is why the bypass moved to the router. Never run `winws2` while the
router bypass runs. Its configuration is `C:\zapret\user\winws2.conf`, with its
lists beside it; its auto-list uses `--hostlist-auto-retrans-threshold=10`,
`--hostlist-auto-retrans-maxseq=1800` and `--hostlist-auto-retrans-reset=0`,
because the defaults added healthy hosts such as the Steam CDN and
`api.anthropic.com`.

To use it as a fallback, stop the router service
(`/opt/etc/init.d/S51nfqws2 stop`), then `net start winws2`; Call of Duty will
not start in that state. To go back, run `C:\zapret\user\zapret-stop.cmd`,
which stops the service and unloads the driver, or
`net stop winws2; sc.exe stop windivert`, then
`/opt/etc/init.d/S51nfqws2 start` on the router and step 3 of
[Diagnose](#diagnose) from the PC. When the driver is stuck,
`sc.exe stop windivert; sc.exe delete windivert`; `winws2` installs it again on
its next start.

## Decisions

| Decision | Detail |
|---|---|
| Tool | zapret2 from the official `bol-van` repositories; community forks are reference only |
| Scope | Discord in browser, app and voice, plus an auto-list; Microsoft, banks, payment sites, `gov.tr` and the work domain are never treated |
| DNS | Omer's NextDNS profile, natively on each device and through the router, with no helper software |
| Updates | by hand only |
| VPN | Cloudflare WARP or another VPN is not a workaround for Discord; a broken strategy gets a new strategy |
| Anti-cheat | never disguise or hide WinDivert from an anti-cheat |
| Security settings | Secure Boot and other security settings change only with Omer's yes |
