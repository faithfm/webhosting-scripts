#!/bin/bash

# Install and look after this server's Cloudflare Tunnel connector.  ADMIN COMMAND - run it from an
# admin account (forge); it uses sudo to write into /etc and to drive systemd.
#
# THE MODEL: one cloudflared service per server, one tunnel named after the server, one route per
# proxied hostname.  Cloudflare's own dashboard remains the place where the tunnel and its routes are
# created - this script never holds a Cloudflare API credential.  What it owns is the BOX half:
#
#   /etc/cloudflared/token                     the tunnel token, root-only, 0600
#   /etc/systemd/system/cloudflared.service    byte-identical to what 'cloudflared service install'
#                                              generates, minus the token-in-argv problem
#
# WHY NOT 'cloudflared service install <token>':  it takes the token as a command-line ARGUMENT, so
# the token lands in /proc/<pid>/cmdline (world-readable) and, when run under sudo, in sudo's log in
# /var/log/auth.log and the journal.  Here the token is read with echo off and travels only through
# shell builtins and pipes - never a command line, an environment variable, or a temp file.  The
# generated unit is otherwise exactly Cloudflare's, so a server installed either way converges.
#
# Re-running 'install' IS the updater and is idempotent: on a server that already has a tunnel it
# offers the pending cloudflared upgrade, re-asserts the unit, and re-prints the dashboard steps for
# whatever is not routed yet.  Nothing is written until you have confirmed what it is about to do.
#
#   wh cf-tunnel install        guided install (or offer an update, if already installed)
#   wh cf-tunnel update         upgrade cloudflared and restart (a few seconds of reconnect)
#   wh cf-tunnel status         read-only health, no sudo - safe for monitoring over ssh
#   wh cf-tunnel test [host..]  status + prove the origin leg and the public path for each site
#   wh cf-tunnel rotate-token   replace the token after a dashboard 'Refresh token'
#   wh cf-tunnel uninstall      remove the connector from this server  (--purge: package + repo too)

set -uo pipefail

TOKEN_DIR=/etc/cloudflared
TOKEN_FILE=$TOKEN_DIR/token
UNIT=/etc/systemd/system/cloudflared.service
UPDATE_UNITS="cloudflared-update.timer cloudflared-update.service"
KEYRING=/usr/share/keyrings/cloudflare-main.gpg
KEY_URL=https://pkg.cloudflare.com/cloudflare-main.gpg
LIST=/etc/apt/sources.list.d/cloudflared.list
LIST_LINE='deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main'
METRICS_PORTS="20241 20242 20243 20244 20245"     # cloudflared binds the first free one on 127.0.0.1
EGRESS_HOST=region1.v2.argotunnel.com
EGRESS_PORT=7844

FAILS=0; WARNS=0; READY_PORT=""
TOK=""; TOK_TUNNEL=""; TOK_ACCOUNT=""; TOK_FP=""

fail()  { echo -e "\nwh cf-tunnel: ERROR: $*\n" >&2; exit 1; }
pass()  { printf '  PASS  %s\n' "$1"; }
info()  { printf '  INFO  %s\n' "$1"; }
warn()  { printf '  WARN  %s\n' "$1"; WARNS=$((WARNS+1)); }
flunk() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }

confirm()  { local a; read -r -p "  $1 [y/N] " a </dev/tty; [[ "$a" =~ ^[Yy]$ ]]; }
need_tty() { [[ -t 0 && -r /dev/tty ]] || fail "this command needs a terminal (token paste + sudo password)"; }
need_sudo(){ sudo -n true 2>/dev/null && return 0; echo "  (sudo may prompt for your password)"; sudo -v || fail "sudo is required"; }

# The unit, exactly as 'cloudflared service install' writes it (verified against cloudflared
# 2026.9.0).  Piped - never captured in $( ) - so the trailing newline survives and
# 'diff' against an existing Cloudflare-generated unit reports no change.
unit_template() {
cat <<'EOF'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

###  cloudflared's local endpoints  ###############################################################

# cloudflared binds the first FREE port of the range, so every consumer resolves it rather than
# assuming 20241 - and re-resolves it per call, because a $( ) subshell cannot hand the answer back.
find_port() {
    local p
    for p in $METRICS_PORTS; do
        curl -s -m 2 -o /dev/null "http://127.0.0.1:$p/ready" && { READY_PORT="$p"; return 0; }
    done
    READY_PORT=""; return 1
}
endpoint()   { [[ -n "$READY_PORT" ]] || find_port || return 1; curl -s -m 3 "http://127.0.0.1:$READY_PORT/$1" 2>/dev/null; }
ready_json() { endpoint ready; }
# Up to 60s for an ACTIVE connection, then a moment longer for the rest of them: cloudflared
# registers its four connections one at a time over a few seconds, and /ready answers 200 on the
# first - so reporting straight away announces "1 connections" for a tunnel about to have four.
wait_ready() {
    local i j n
    j=""
    for ((i=0; i<30; i++)); do
        j=$(ready_json) || j=""
        [[ -n "$j" && "$(jq -r '.status // 0' <<<"$j")" == 200 ]] && break
        j=""; sleep 2
    done
    [[ -n "$j" ]] || return 1
    for ((i=0; i<6; i++)); do
        n=$(jq -r '.readyConnections // 0' <<<"$j")
        [[ "$n" -ge 4 ]] && break
        sleep 2; j=$(ready_json) || break
    done
    echo "$j"
}
metrics()  { endpoint metrics; }
requests() { metrics | awk '/^cloudflared_tunnel_total_requests /{print $2}'; }
locations(){ metrics | awk -F'"' '/^cloudflared_tunnel_server_locations/{print $4}' | sort -u | paste -sd, -; }
routed()   { endpoint config | jq -r '.config.ingress[]?.hostname // empty' 2>/dev/null | grep -v '^$' | sort -u; }

# Hostnames this server serves over TLS (modern Forge layout: one file per site in sites-enabled).
sites() {
    grep -lE '^[[:space:]]*listen[[:space:]]+(\[::\]:)?443[[:space:]]+ssl' /etc/nginx/sites-enabled/* 2>/dev/null \
      | xargs -r grep -hE '^[[:space:]]*server_name[[:space:]]' 2>/dev/null \
      | tr -d ';' | awk '{for (i=2; i<=NF; i++) print $i}' \
      | grep -vE '^(default|_|localhost|[0-9.]+)$' | sort -u
}

# A token on a command line would show up here.  Read /proc directly: 'ps | grep eyJ' matches itself.
token_in_cmdline() {
    local f c n=0
    for f in /proc/[0-9]*/cmdline; do
        c=$(tr '\0' ' ' < "$f" 2>/dev/null) || continue
        [[ "$c" == *"eyJhIjoi"* ]] && n=$((n+1))
    done
    echo "$n"
}

###  the token  ###################################################################################

# Accepts the whole 'sudo cloudflared service install eyJ...' command or just the token.  Decodes it
# locally (it is base64 JSON) to show which tunnel it belongs to - the secret inside is never read,
# printed, or passed to another process.
read_token() {
    local raw meta
    echo
    echo "  Paste the token now - either the whole 'sudo cloudflared service install eyJ...' line"
    echo "  from the dashboard, or just the eyJ... part.  Nothing is echoed to the screen."
    read -rs -p "  Token: " raw </dev/tty; echo
    [[ "$raw" =~ (eyJ[A-Za-z0-9+/=]+) ]] || fail "no 'eyJ...' token found in what you pasted"
    TOK="${BASH_REMATCH[1]}"
    meta=$(printf '%s' "$TOK" | base64 -d 2>/dev/null) \
        || fail "that token is not valid base64 - copy it again from the dashboard"
    TOK_TUNNEL=$(printf '%s' "$meta" | jq -r '.t // empty' 2>/dev/null)
    TOK_ACCOUNT=$(printf '%s' "$meta" | jq -r '.a // empty' 2>/dev/null)
    meta=""
    [[ "$TOK_TUNNEL" =~ ^[0-9a-f-]{36}$ ]] || fail "no tunnel id inside that token - is the paste complete?"
    TOK_FP=$(printf '%s' "$TOK" | sha256sum | cut -c1-8)
    echo
    echo "    tunnel       $TOK_TUNNEL"
    echo "    account      $TOK_ACCOUNT"
    echo "    fingerprint  $TOK_FP"
    echo "  Check those against the tunnel's page in the dashboard before continuing."
    echo
}

write_token() {
    sudo install -d -m 0755 "$TOKEN_DIR" || fail "could not create $TOKEN_DIR"
    printf '%s' "$TOK" | sudo sh -c "umask 077; cat > $TOKEN_FILE.new && mv -f $TOKEN_FILE.new $TOKEN_FILE" \
        || fail "could not write $TOKEN_FILE"
    sudo chown root:root "$TOKEN_FILE" && sudo chmod 0600 "$TOKEN_FILE" || fail "could not secure $TOKEN_FILE"
}
installed_tunnel() { sudo cat "$TOKEN_FILE" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null | jq -r '.t // empty' 2>/dev/null; }
installed_fp()     { sudo cat "$TOKEN_FILE" 2>/dev/null | tr -d '\n' | sha256sum | cut -c1-8; }

# Bring the unit to the expected shape and retire the update timer 'service install' leaves behind
# (a daily no-op for apt installs, since cloudflared refuses to self-update a packaged binary).
#
# Echoes yes ONLY when the unit itself changed - ie: when the caller must restart cloudflared.
# Retiring those update units needs a daemon-reload but never a restart, so a tunnel that is
# already serving traffic is not interrupted just to tidy up units it does not use.
converge_unit() {
    local unit_changed=no touched=no u
    if ! unit_template | diff -q - "$UNIT" >/dev/null 2>&1; then
        unit_template | sudo tee "$UNIT" >/dev/null || fail "could not write $UNIT"
        sudo chmod 0644 "$UNIT"; unit_changed=yes; touched=yes
    fi
    for u in $UPDATE_UNITS; do
        if [[ -e "/etc/systemd/system/$u" ]]; then
            sudo systemctl disable --now "$u" >/dev/null 2>&1
            sudo rm -f "/etc/systemd/system/$u" \
                && { echo "  Retired $u (a daily no-op on apt installs)." >&2; touched=yes; }
        fi
    done
    [[ "$touched" == yes ]] && sudo systemctl daemon-reload
    sudo systemctl enable cloudflared >/dev/null 2>&1
    echo "$unit_changed"
}

###  printed guidance - the dashboard half of the job  ############################################

guide_create() {
cat <<EOF

  DASHBOARD - create the tunnel (once per server)
    1. Networking -> Tunnels -> Create a tunnel -> Cloudflared
    2. Name it:  $1
    3. Save.  The next screen shows an install command - choose Debian/Ubuntu; the architecture
       does not matter here (the package comes from apt), only the token does.
    4. Copy that command; you will paste it below.  It is a bearer credential: anyone holding it
       can run this tunnel, so keep it out of tickets, chat and documents.
       (You can always get it again later: tunnel -> Overview -> Add a replica.)
EOF
}

guide_routes() {
    local h r s
    r=$(routed); s=$(sites)
    echo
    echo "  SITES ON THIS SERVER                          tunnel route"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        if grep -qxF "$h" <<<"$r"; then printf '    %-44s routed\n' "$h"
        else                            printf '    %-44s NOT YET\n' "$h"; fi
    done <<<"$s"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        grep -qxF "$h" <<<"$s" || printf '    %-44s routed (not an nginx site here)\n' "$h"
    done <<<"$r"
cat <<EOF

  For each site marked NOT YET - Networking -> Tunnels -> $1 -> Routes -> Add route
  -> Published application:
      Subdomain / Domain        <host> / <zone>   (the 'Full hostname' preview must read <host>;
                                Path stays empty)
      Service URL               https://localhost:443     (one field, scheme included)
      Additional application settings -> TLS -> Match SNI to host:  ON
                                (so cloudflared presents <host> as the SNI - nginx's catch-all
                                rejects the default 'localhost')
      everything else at its default: 'Disable TLS certificate verification' off, CA Pool
      empty, HTTP host header untouched
  Delete the hostname's A, AAAA or CNAME record first (DNS -> Records - whatever points at the
  old server): Cloudflare refuses the route while one exists.  Saving the route re-creates it as
  a proxied CNAME to $2.cfargotunnel.com.
  An apex and its www each need their own route.
  Then, in the hostname's zone, either add it to the zone's HTTP-to-HTTPS redirect rule
  (Rules -> Redirect Rules) or turn on SSL/TLS -> Edge Certificates -> Always Use HTTPS: without
  either, http:// requests are served unencrypted once the tunnel is the only path in (there is
  no longer a port 80 on the origin to redirect them).

  Check it with:   wh cf-tunnel test
  Once soaked:     close public 80/443 at the firewall (on AWS, detach the http/https security
                   group from this instance) - the tunnel is then the only way in.
EOF
}

###  verbs  #######################################################################################

cmd_status() {
    local v j n u u_ok
    echo -e "\nwh cf-tunnel status: $(hostname)\n"
    v=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null)
    if [[ ! -f "$UNIT" ]]; then                  # no tunnel here is a state, not a fault
        [[ -n "$v" ]] && info "cloudflared $v is installed, but there is no tunnel service ($UNIT)" \
                      || info "no tunnel on this server - 'wh cf-tunnel install' sets one up"
        echo; return 2
    fi
    [[ -n "$v" ]] && pass "cloudflared $v ($(dpkg --print-architecture))" \
                  || flunk "the unit exists but the cloudflared package does not"
    if unit_template | diff -q - "$UNIT" >/dev/null 2>&1; then
        pass "unit matches the expected template"
    elif grep -q -- '--token-file' "$UNIT"; then
        warn "unit differs from the expected template but does use --token-file ('wh cf-tunnel install' re-asserts it)"
    else
        flunk "unit does NOT use --token-file - the token may be exposed in 'ps' ('wh cf-tunnel install')"
    fi
    [[ "$(systemctl is-enabled cloudflared 2>/dev/null)" == enabled ]] \
        && pass "enabled at boot" || flunk "not enabled at boot"
    [[ "$(systemctl is-active cloudflared 2>/dev/null)" == active ]] \
        && pass "service active" || flunk "service not running ('sudo journalctl -u cloudflared -n 30')"
    u_ok=$(stat -c '%U %a' "$TOKEN_FILE" 2>/dev/null)
    [[ "$u_ok" == "root 600" ]] && pass "token file root-only (0600)" \
        || flunk "token file is '${u_ok:-missing}', expected 'root 600'"
    n=$(token_in_cmdline)
    [[ "$n" == 0 ]] && pass "no token on any process command line" || flunk "$n process(es) carry a token in argv"
    n=$(find "$TOKEN_DIR" -mindepth 1 ! -name token -printf '%f ' 2>/dev/null)
    [[ -z "$n" ]] || warn "extra files in $TOKEN_DIR: $n (spare copies of a credential - remove them)"
    for u in $UPDATE_UNITS; do
        [[ -e "/etc/systemd/system/$u" ]] && warn "$u is installed (a daily no-op for apt builds; 'install' removes it)"
    done
    if j=$(ready_json); then
        [[ "$(jq -r '.status' <<<"$j")" == 200 ]] \
            && pass "connected: $(jq -r '.readyConnections' <<<"$j") connections via $(locations), connector $(jq -r '.connectorId' <<<"$j" | cut -c1-8)" \
            || flunk "cloudflared is running but has NO connection to Cloudflare"
    else
        flunk "no answer from cloudflared's metrics endpoint on 127.0.0.1:${METRICS_PORTS// /,}"
    fi
    n=$(apt-cache policy cloudflared 2>/dev/null | awk '/Candidate:/{print $2}')
    [[ -n "$n" && "$n" != "$v" && "$n" != "(none)" ]] && info "cloudflared $n is available ('wh cf-tunnel update')"
    echo
    [[ $FAILS -gt 0 ]] && { echo "  $FAILS problem(s), $WARNS warning(s)."; echo; return 1; }
    [[ $WARNS -gt 0 ]] && { echo "  Healthy, $WARNS warning(s)."; echo; return 0; }
    echo "  Healthy."; echo; return 0
}

cmd_test() {
    local rc h hosts r code cert san end pub ray before after
    cmd_status; rc=$?
    [[ $rc -eq 2 ]] && return 2
    hosts="$*"; [[ -z "$hosts" ]] && hosts=$(sites)
    [[ -z "$hosts" ]] && { info "no TLS sites in /etc/nginx/sites-enabled to test"; echo; return $rc; }
    r=$(routed)
    for h in $hosts; do
        echo "  $h"
        code=$(curl -sk -m 8 --resolve "$h:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$h/" 2>/dev/null)
        # 4xx passes too: cloudflared relays any HTTP answer (eg: a basic-auth 401); only 000 means a 502.
        [[ "$code" =~ ^[1-9][0-9]{2}$ ]] && pass "  origin leg on loopback (SNI $h): HTTP $code" \
            || flunk "  origin leg on loopback (SNI $h): ${code:-no answer} - cloudflared would return 502"
        cert=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null \
               | openssl x509 -noout -issuer -enddate -ext subjectAltName 2>/dev/null)
        san=$(grep -c "DNS:$h\(,\|$\)" <<<"$cert")
        end=$(sed -n 's/^notAfter=//p' <<<"$cert")
        [[ "$san" -gt 0 ]] && pass "  certificate covers $h, expires $end" \
            || flunk "  certificate does not name $h - the TLS handshake with SNI $h would fail"
        pub=$(curl -sI -m 8 "https://$h/" 2>/dev/null)
        code=$(sed -n '1s#^[^ ]* \([0-9]*\).*#\1#p' <<<"$pub")
        ray=$(grep -ci '^cf-ray:' <<<"$pub")
        if [[ "$ray" -gt 0 ]]; then pass "  public https://$h/: HTTP $code via Cloudflare"
        else warn "  public https://$h/: ${code:-no answer}, no cf-ray - not proxied, so it cannot be tunnelled"; fi
        code=$(curl -sI -m 8 "http://$h/" 2>/dev/null | sed -n '1s#^[^ ]* \([0-9]*\).*#\1#p')
        [[ "$code" =~ ^30[0-9]$ ]] && pass "  http://$h/ redirects ($code)" \
            || warn "  http://$h/ answers $code - add it to your HTTP-to-HTTPS redirect rule"
        if grep -qxF "$h" <<<"$r"; then
            before=$(requests)
            curl -s -m 8 -o /dev/null "https://$h/?wh-cf-tunnel-probe=1" 2>/dev/null
            after=$(requests)
            [[ -n "$before" && -n "$after" && "$after" -gt "$before" ]] \
                && pass "  served through THIS tunnel (connector request count rose)" \
                || warn "  routed here, but the request count did not rise - traffic may be taking another path"
        else
            info "  no tunnel route for this hostname yet"
        fi
    done
    echo
    [[ $FAILS -gt 0 ]] && return 1 || return 0
}

cmd_update() {
    local j
    [[ -f "$UNIT" ]] || fail "no tunnel on this server ('wh cf-tunnel install')"
    need_sudo
    echo -e "\n  Upgrading cloudflared ..."
    sudo apt-get update -qq || fail "apt-get update failed"
    sudo apt-get install --only-upgrade -y -qq cloudflared || fail "could not upgrade cloudflared"
    converge_unit >/dev/null
    sudo systemctl restart cloudflared || fail "could not restart cloudflared"
    j=$(wait_ready) || fail "cloudflared did not reconnect - 'sudo journalctl -u cloudflared -n 30'"
    echo "  Now $(cloudflared --version 2>/dev/null | awk '{print $3}'), $(jq -r .readyConnections <<<"$j") connections via $(locations)."
}

cmd_install() {
    local name changed cur cand j c hlp
    need_tty
    for c in curl jq sudo systemctl; do command -v "$c" >/dev/null || fail "'$c' not found"; done

    if [[ -f "$UNIT" ]]; then                      # already installed - converge, then offer the upgrade
        cmd_status
        need_sudo
        echo "  Checking for a newer cloudflared ..."
        sudo apt-get update -qq >/dev/null 2>&1
        cur=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null)
        cand=$(apt-cache policy cloudflared 2>/dev/null | awk '/Candidate:/{print $2}')
        if [[ -n "$cand" && "$cand" != "$cur" && "$cand" != "(none)" ]]; then
            echo "  installed $cur, available $cand"
            confirm "Upgrade and restart the tunnel (a few seconds of reconnect)?" && cmd_update
        else
            echo "  cloudflared $cur is current."
        fi
        changed=$(converge_unit)
        if [[ "$changed" == yes ]]; then
            echo "  Unit brought to the expected shape - restarting."
            sudo systemctl restart cloudflared
            wait_ready >/dev/null || fail "cloudflared did not reconnect - 'sudo journalctl -u cloudflared -n 30'"
        fi
        ready_json >/dev/null
        guide_routes "$(hostname)" "$(installed_tunnel)"
        return 0
    fi

    echo -e "\nwh cf-tunnel install: $(hostname)\n"
    timeout 5 bash -c "</dev/tcp/$EGRESS_HOST/$EGRESS_PORT" 2>/dev/null \
        || fail "cannot open $EGRESS_HOST:$EGRESS_PORT - a tunnel needs outbound TCP 7844"
    echo "  This will:"
    echo "    - add Cloudflare's apt repository (if missing) and install the 'cloudflared' package"
    echo "    - write $TOKEN_FILE (root, 0600) from a token you paste"
    echo "    - write $UNIT, then enable and start the service"
    echo "  Nothing routes through the tunnel until you add routes in the dashboard afterwards."
    echo
    confirm "Continue?" || { echo "  Nothing changed."; exit 0; }
    need_sudo

    if [[ ! -s "$KEYRING" ]]; then
        echo "  Adding Cloudflare's package signing key ..."
        curl -fsSL "$KEY_URL" | sudo tee "$KEYRING" >/dev/null || fail "could not fetch $KEY_URL"
        sudo chmod 0644 "$KEYRING"
    fi
    if [[ "$(cat "$LIST" 2>/dev/null)" != "$LIST_LINE" ]]; then
        echo "  Adding the cloudflared apt repository ..."
        echo "$LIST_LINE" | sudo tee "$LIST" >/dev/null || fail "could not write $LIST"
    fi
    echo "  Installing the cloudflared package ..."
    sudo apt-get update -qq || fail "apt-get update failed"
    sudo apt-get install -y -qq cloudflared || fail "could not install cloudflared"
    # Read the help into a variable first: 'cloudflared ... | grep -q' lets grep exit early, leaving
    # cloudflared with SIGPIPE, which 'set -o pipefail' would report as failure on a version that matched.
    hlp=$(cloudflared tunnel run --help 2>&1)
    [[ "$hlp" == *--token-file* ]] || fail "this cloudflared has no --token-file support - too old for this script"
    echo "  Installed $(cloudflared --version 2>/dev/null | awk '{print $3}')."

    read -r -p "  Tunnel name [$(hostname)]: " name </dev/tty
    name="${name:-$(hostname)}"
    guide_create "$name"
    read_token
    confirm "Install this token and start the tunnel?" || { echo "  Nothing written."; exit 0; }

    write_token
    converge_unit >/dev/null
    sudo systemctl restart cloudflared || fail "could not start cloudflared"
    echo "  Waiting for the tunnel to connect ..."
    if ! j=$(wait_ready); then
        echo; sudo journalctl -u cloudflared -n 20 --no-pager
        sudo systemctl disable --now cloudflared >/dev/null 2>&1
        sudo rm -f "$UNIT" "$TOKEN_FILE"; sudo systemctl daemon-reload
        fail "the tunnel did not connect - the unit and token have been removed again (the package stays).
       The usual cause is a stale token: copy the current one from the dashboard
       (tunnel -> Overview -> Add a replica) and run 'wh cf-tunnel install' again."
    fi
    echo "  Connected: $(jq -r .readyConnections <<<"$j") connections via $(locations)."
    guide_routes "$name" "$TOK_TUNNEL"
}

cmd_rotate() {
    local cur_tunnel cur_fp j
    need_tty
    [[ -f "$UNIT" ]] || fail "no tunnel on this server ('wh cf-tunnel install')"
    need_sudo
    cur_tunnel=$(installed_tunnel); cur_fp=$(installed_fp)
    [[ -n "$cur_tunnel" ]] || fail "cannot read the installed token at $TOKEN_FILE"
    cat <<EOF

  DASHBOARD - refresh the token first
    Networking -> Tunnels -> $(hostname) -> Overview -> Refresh token, then copy the install command.
    Tunnel $cur_tunnel, token now installed here: $cur_fp
    After a refresh the OLD token can no longer connect, so finish this now: the tunnel keeps
    running on its current connections until the restart below.
EOF
    read_token
    [[ "$TOK_TUNNEL" == "$cur_tunnel" ]] \
        || fail "that token is for tunnel $TOK_TUNNEL, but this server runs $cur_tunnel - wrong tunnel"
    [[ "$TOK_FP" != "$cur_fp" ]] \
        || fail "that is the token already installed here - refresh it in the dashboard first"
    confirm "Replace the token and restart the tunnel?" || { echo "  Nothing written."; exit 0; }
    write_token
    sudo systemctl restart cloudflared || fail "could not restart cloudflared"
    j=$(wait_ready) || fail "the new token did not connect - 'sudo journalctl -u cloudflared -n 30'.
       The old token cannot be restored (the refresh retired it); copy the current one from
       tunnel -> Overview -> Add a replica and run 'wh cf-tunnel rotate-token' again."
    echo "  Rotated to $TOK_FP: $(jq -r .readyConnections <<<"$j") connections via $(locations)."
}

cmd_uninstall() {
    local hosts u
    need_tty
    [[ -f "$UNIT" ]] || fail "no tunnel on this server"
    need_sudo
    ready_json >/dev/null 2>&1
    hosts=$(routed)
    echo
    if [[ -n "$hosts" ]]; then
        echo "  THESE HOSTNAMES ARE SERVED THROUGH THIS TUNNEL AND WILL STOP WORKING (Cloudflare 1033):"
        echo "$hosts" | sed 's/^/      /'
        echo "  Move or delete their routes in the dashboard first if that is not what you want."
    else
        echo "  This tunnel serves no routes, so nothing goes offline."
    fi
    confirm "Remove the cloudflared connector from $(hostname)?" || { echo "  Nothing changed."; exit 0; }
    sudo systemctl disable --now cloudflared >/dev/null 2>&1
    sudo rm -f "$UNIT"
    for u in $UPDATE_UNITS; do sudo rm -f "/etc/systemd/system/$u"; done
    sudo rm -f "$TOKEN_FILE"; sudo rmdir "$TOKEN_DIR" 2>/dev/null
    sudo systemctl daemon-reload; sudo systemctl reset-failed cloudflared 2>/dev/null
    echo "  Service, unit and token removed."
    if [[ "${1:-}" == "--purge" ]]; then
        sudo apt-get purge -y -qq cloudflared >/dev/null 2>&1
        sudo rm -f "$LIST" "$KEYRING"
        sudo apt-get update -qq >/dev/null 2>&1
        echo "  Package, repository and signing key removed."
    else
        echo "  The cloudflared package is still installed (--purge removes it and the apt repo)."
    fi
    cat <<EOF

  IN THE DASHBOARD, finish the job:
    - delete the tunnel (Networking -> Tunnels), or if you are rebuilding this server, leave it and
      use Refresh token so the copy that was on this box can no longer be used.
EOF
}

###  dispatch  ####################################################################################

case "${1:-}" in
    install)      shift; cmd_install "$@" ;;
    update)       shift; cmd_update ;;
    status)       shift; cmd_status ;;
    test)         shift; cmd_test "$@" ;;
    rotate-token) shift; cmd_rotate ;;
    uninstall)    shift; cmd_uninstall "${1:-}" ;;
    *)
        cat <<EOF

wh cf-tunnel - this server's Cloudflare Tunnel connector

  wh cf-tunnel install        guided install; on a server that already has one, offers the update
  wh cf-tunnel update         upgrade cloudflared and restart (a few seconds of reconnect)
  wh cf-tunnel status         read-only health check, no sudo needed
  wh cf-tunnel test [host..]  status, plus the origin leg and public path for each site
  wh cf-tunnel rotate-token   install a token refreshed in the dashboard
  wh cf-tunnel uninstall      remove the connector  (--purge also removes package and apt repo)

EOF
        [[ -n "${1:-}" ]] && exit 1 || exit 0 ;;
esac
