#!/usr/bin/env python3
"""Configure Tvheadend for the OnAir GT USB HDTV through its JSON API.

Standard library only. Credentials are read from the environment, never argv:
  TVH_USER / TVH_PASS          account used to talk to the API (optional)
  TVH_NEW_USER / TVH_NEW_PASS  admin account to create or update ("configure")

Commands:
  check-auth   print "user" (TVH_USER works as admin), "anon" (anonymous admin
               access, e.g. after -C first run) or "none"
  configure    admin account, lock-down, ATSC-T network + muxes from a dvbv5
               scan file, enable only the ATSC-T frontend, scan, map channels
  status       short summary (used by onairgt-doctor.sh)
  viewers      number of active non-scan subscriptions

Exit codes: 0 ok, 1 error, 2 authentication, 3 tuner not found in tvheadend.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USB_VID, USB_PID = "11ba", "1101"
COMMENT = "Created by OnAirHDTV_Linux_Driver installer"


class AuthError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


class Api:
    """Minimal Tvheadend API client.

    Tvheadend serves anonymous requests with the rights of the anonymous
    access entry and does not reject wrong credentials on API calls, so the
    challenge is fetched from /login first and credentials are sent with every
    request; login() checks them explicitly.
    """

    def __init__(self, url, user=None, password=None):
        self.root = url.rstrip("/") + "/"
        self.user, self.password = user, password
        self.digest = None  # (realm, nonce, opaque, algorithm)
        self.basic = False
        self.nc = 0

    def _challenge(self, headers):
        hdr = headers.get("WWW-Authenticate", "")
        if hdr.lower().startswith("digest"):
            kv = dict(re.findall(r'(\w+)="?([^",]*)"?', hdr))
            self.digest = (kv.get("realm", ""), kv.get("nonce", ""), kv.get("opaque"),
                           kv.get("algorithm", "MD5"))
            self.nc = 0
        else:
            self.basic = True

    def _digest_header(self, method, uri):
        realm, nonce, opaque, algo = self.digest
        h = hashlib.sha256 if algo.upper().startswith("SHA-256") else hashlib.md5

        def hx(s):
            return h(s.encode()).hexdigest()

        self.nc += 1
        nc = "%08x" % self.nc
        cnonce = os.urandom(8).hex()
        ha1 = hx("%s:%s:%s" % (self.user, realm, self.password))
        ha2 = hx("%s:%s" % (method, uri))
        resp = hx("%s:%s:%s:%s:auth:%s" % (ha1, nonce, nc, cnonce, ha2))
        parts = ['username="%s"' % self.user, 'realm="%s"' % realm, 'nonce="%s"' % nonce,
                 'uri="%s"' % uri, 'response="%s"' % resp, "qop=auth", "nc=" + nc,
                 'cnonce="%s"' % cnonce, "algorithm=" + algo]
        if opaque:
            parts.append('opaque="%s"' % opaque)
        return "Digest " + ", ".join(parts)

    def _send(self, path, data=None):
        url = self.root + path
        method = "POST" if data is not None else "GET"
        req = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        if self.user and self.digest:
            req.add_header("Authorization", self._digest_header(method, urllib.parse.urlparse(url).path))
        elif self.user and self.basic:
            tok = base64.b64encode(("%s:%s" % (self.user, self.password)).encode()).decode()
            req.add_header("Authorization", "Basic " + tok)
        return _opener.open(req, timeout=30)

    def _prime(self):
        try:
            self._send("login").close()
        except urllib.error.HTTPError as e:
            if e.code == 401:
                self._challenge(e.headers)

    def login(self):
        """True if the credentials are accepted (always True without credentials)."""
        if not self.user:
            return True
        self._prime()
        for _ in range(2):
            try:
                self._send("login").close()
                return True
            except urllib.error.HTTPError as e:
                if 300 <= e.code < 400:
                    return True
                if e.code != 401:
                    return False
                self._challenge(e.headers)  # stale nonce
        return False

    def call(self, path, **params):
        data = urllib.parse.urlencode({k: (json.dumps(v) if isinstance(v, (dict, list, bool)) else v)
                                       for k, v in params.items()}).encode()
        if self.user and not (self.digest or self.basic):
            self._prime()
        for attempt in range(3):
            try:
                with self._send("api/" + path, data) as r:
                    text = r.read().decode("utf-8", "replace")
                return json.loads(text) if text.strip() else {}
            except urllib.error.HTTPError as e:
                if e.code != 401 or not self.user or attempt == 2:
                    if e.code in (401, 403):
                        raise AuthError("HTTP %d on %s" % (e.code, path))
                    raise
                self._challenge(e.headers)
        raise AuthError(path)

    def grid(self, path, **params):
        params.setdefault("limit", 100000)
        return self.call(path, **params).get("entries", [])


def is_admin(api):
    def api_ok(a):
        try:
            a.call("access/entry/grid", limit=1)
            return True
        except (AuthError, urllib.error.HTTPError):
            return False

    if not api.user or not api_ok(Api(api.root)):
        return api_ok(api)
    # Anonymous access is admin, so API success proves nothing about the
    # credentials. /login does (it answers 403 to wrong ones, but also to the
    # "superuser" file account, which therefore only works without anonymous admin).
    return api.login() and api_ok(api)


def log(msg):
    print("    " + msg, flush=True)


# ------------------------------------------------------------------ scan file
def read_scan_file(path):
    name, freqs, cur = None, [], {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            m = re.match(r"#\s*name:\s*(.+)", s, re.I)
            if m and not name:
                name = m.group(1).strip()
            if s.startswith("[") and cur:
                freqs.append(cur)
                cur = {}
            m = re.match(r"(\w+)\s*=\s*(\S+)", s)
            if m:
                cur[m.group(1).upper()] = m.group(2)
        if cur:
            freqs.append(cur)
    muxes = []
    for c in freqs:
        if "FREQUENCY" not in c:
            continue
        mod = c.get("MODULATION", "VSB/8").upper()
        muxes.append({"frequency": int(c["FREQUENCY"]),
                      "modulation": "VSB/8" if mod in ("VSB/8", "8VSB") else mod})
    if not name:
        name = os.path.basename(path)
    return name, muxes


# ------------------------------------------------------------------ steps
def ensure_admin(api, user, password):
    entries = api.grid("access/entry/grid")
    ent = next((e for e in entries if e.get("username") == user), None)
    rights = {"enabled": True, "username": user, "prefix": "0.0.0.0/0,::/0",
              "change": ["change_rights"], "streaming": ["basic", "advanced", "htsp"],
              "dvr": ["basic", "htsp", "all", "all_rw", "failed"], "webui": True, "admin": True}
    if ent:
        api.call("idnode/save", node=dict(rights, uuid=ent["uuid"]))
    else:
        api.call("access/entry/create", conf=dict(rights, comment=COMMENT))
    pw = next((p for p in api.grid("passwd/entry/grid") if p.get("username") == user), None)
    if pw:
        api.call("idnode/save", node={"uuid": pw["uuid"], "enabled": True, "password": password})
    else:
        api.call("passwd/entry/create", conf={"enabled": True, "username": user,
                                              "password": password, "comment": COMMENT})
    log("admin account '%s' %s" % (user, "updated" if ent else "created"))


def lock_down(api):
    """Remove anonymous admin entries (the wide-open entry created by -C)."""
    victims = [e["uuid"] for e in api.grid("access/entry/grid")
               if e.get("username", "") in ("", "*") and e.get("admin")]
    if victims:
        api.call("idnode/delete", uuid=victims)
        log("removed %d anonymous admin access entr%s" % (len(victims), "y" if len(victims) == 1 else "ies"))
    try:
        api.call("wizard/cancel")
    except Exception:
        pass


def sysfs_is_onair(path):
    if not path:
        return False
    d = os.path.realpath(os.path.join("/sys", path.splitlines()[0].lstrip("/")))
    while d and d != "/":
        try:
            with open(os.path.join(d, "idVendor")) as f:
                vid = f.read().strip()
            with open(os.path.join(d, "idProduct")) as f:
                pid = f.read().strip()
            return (vid, pid) == (USB_VID, USB_PID)
        except OSError:
            d = os.path.dirname(d)
    return False


def params_of(node):
    return {p["id"]: p.get("value") for p in node.get("params", [])}


def find_frontends(api, wait=30):
    """Return [(adapter_text, frontend_node)] for the OnAir GT adapter(s)."""
    deadline = time.time() + wait
    while True:
        found, lgdt = [], []
        for ad in api.call("hardware/tree", uuid="root") or []:
            fes = api.call("hardware/tree", uuid=ad["uuid"]) or []
            for fe in fes:
                p = params_of(fe)
                if sysfs_is_onair(p.get("sysfs_device") or ""):
                    found.append((ad["text"], fe))
                elif "LGDT3303" in ad.get("text", ""):
                    lgdt.append((ad["text"], fe))
        if found:
            return found
        # No usable sysfs path (e.g. unusual container setup): accept a single LGDT3303 adapter.
        if lgdt and len({t for t, _ in lgdt}) == 1:
            return lgdt
        if time.time() > deadline:
            return []
        time.sleep(3)


def ensure_network(api, name):
    nets = api.grid("mpegts/network/grid")
    net = next((n for n in nets if n.get("networkname") == name), None)
    if net:
        log("network '%s' exists" % name)
        return net["uuid"]
    r = api.call("mpegts/network/create", **{"class": "dvb_network_atsc_t", "conf": {
        "networkname": name, "bouquet": False, "autodiscovery": 0, "skipinitscan": True,
        "idlescan": False, "sid_chnum": False, "ignore_chnum": False}})
    log("network '%s' created" % name)
    return r["uuid"]


def ensure_muxes(api, nuuid, muxes):
    existing = [m["frequency"] for m in api.grid("mpegts/mux/grid") if m.get("network_uuid") == nuuid]
    added = 0
    for m in muxes:
        if any(abs(m["frequency"] - e) < 100000 for e in existing):
            continue
        api.call("mpegts/network/mux_create", uuid=nuuid, conf={
            "enabled": 1, "frequency": m["frequency"], "modulation": m["modulation"], "delsys": "ATSC-T"})
        existing.append(m["frequency"])
        added += 1
    log("muxes: %d added, %d total" % (added, len(existing)))


def setup_frontends(api, fes, nuuid):
    for adtext, fe in fes:
        p = params_of(fe)
        cls = fe.get("class", "")
        if cls.endswith("atsc_t"):
            nets = list(p.get("networks") or [])
            if nuuid not in nets:
                nets.append(nuuid)
            api.call("idnode/save", node={"uuid": fe["uuid"], "enabled": True, "networks": nets})
            log("enabled  %s" % fe["text"])
        elif cls.endswith("atsc_c"):
            # The LGDT3303 is exposed twice (ATSC-T and ATSC-C). With both enabled
            # scans fail with "type does not match", so keep only ATSC-T.
            api.call("idnode/save", node={"uuid": fe["uuid"], "enabled": False})
            log("disabled %s" % fe["text"])


def scan(api, nuuid, timeout):
    api.call("mpegts/network/scan", uuid=nuuid)
    t0, last = time.time(), None
    time.sleep(3)
    while True:
        muxes = [m for m in api.grid("mpegts/mux/grid") if m.get("network_uuid") == nuuid]
        left = sum(1 for m in muxes if m.get("scan_state", 0) != 0)
        svcs = sum(m.get("num_svc", 0) for m in muxes)
        locked = sum(1 for m in muxes if m.get("num_svc", 0) > 0)
        line = "scan: %d/%d muxes done, %d with services, %d services" % (
            len(muxes) - left, len(muxes), locked, svcs)
        if line != last:
            log(line)
            last = line
        if left == 0:
            return svcs
        if time.time() - t0 > timeout:
            log("scan still running after %ds; continuing (tvheadend keeps scanning)" % timeout)
            return svcs
        time.sleep(5)


def map_channels(api, network_name, map_encrypted):
    # Channels without any service cannot play; they are left over when the
    # mapping was not saved before a restart. Remove them so the services map again.
    empty = [c["uuid"] for c in api.grid("channel/grid") if not c.get("services")]
    if empty:
        api.call("idnode/delete", uuid=empty)
        log("removed %d channels without services" % len(empty))
    svcs = [s for s in api.grid("mpegts/service/grid") if s.get("network") == network_name]
    todo = [s["uuid"] for s in svcs if not s.get("channel") and s.get("svcname")
            and s.get("enabled", True) and (map_encrypted or not s.get("encrypted"))]
    before = len(api.grid("channel/grid"))
    if todo:
        api.call("service/mapper/save", node={
            "services": todo, "check_availability": False, "encrypted": True,
            "merge_same_name": False, "type_tags": False, "provider_tags": False,
            "network_tags": False})
        # The mapper runs asynchronously and its status may still describe an
        # earlier run, so wait until the channel count stops growing.
        last, stable = -1, 0
        for _ in range(150):
            time.sleep(2)
            n = len(api.grid("channel/grid"))
            if n >= before + len(todo):
                break
            st = api.call("service/mapper/status")
            stable = stable + 1 if n == last and not st.get("active") else 0
            if stable >= 5:
                break
            last = n
    chans = api.grid("channel/grid")
    log("services: %d, newly mapped: %d, channels: %d" % (len(svcs), len(todo), len(chans)))
    return len(chans)


# ------------------------------------------------------------------ commands
def api_from_env(url):
    return Api(url, os.environ.get("TVH_USER") or None, os.environ.get("TVH_PASS") or None)


def cmd_check_auth(a):
    api = api_from_env(a.url)
    if api.user and is_admin(api):
        print("user")
    elif is_admin(Api(a.url)):
        print("anon")
    else:
        print("none")


def cmd_configure(a):
    api = api_from_env(a.url)
    if not is_admin(api):
        if api.user and is_admin(Api(a.url)):
            api = Api(a.url)
        else:
            print("error: no admin access to tvheadend at %s" % a.url, file=sys.stderr)
            return 2
    new_user, new_pass = os.environ.get("TVH_NEW_USER"), os.environ.get("TVH_NEW_PASS")
    if new_user and new_pass:
        ensure_admin(api, new_user, new_pass)
        admin = Api(a.url, new_user, new_pass)
        if not is_admin(admin):
            print("error: the new admin account does not authenticate; not locking down", file=sys.stderr)
            return 2
        api = admin
        lock_down(api)
    if not a.preset_file:
        return 0

    name, muxes = read_scan_file(a.preset_file)
    if a.network_name:
        name = a.network_name
    fes = find_frontends(api)
    if not fes:
        print("error: tvheadend does not see the OnAir GT tuner (device unplugged, driver not loaded,"
              " or /dev/dvb not passed to the container)", file=sys.stderr)
        return 3
    log("tuner: %s" % fes[0][0])
    nuuid = ensure_network(api, name)
    ensure_muxes(api, nuuid, muxes)
    setup_frontends(api, fes, nuuid)
    if a.no_scan:
        log("scan skipped (--no-scan)")
        return 0
    scan(api, nuuid, a.scan_timeout)
    n = map_channels(api, name, a.map_encrypted)
    if n == 0:
        print("warning: no channels found; check the antenna/cable and the frequency preset", file=sys.stderr)
    return 0


def cmd_status(a):
    api = api_from_env(a.url)
    try:
        info = api.call("serverinfo")
        print("server: %s %s (api %s)" % (info.get("name"), info.get("sw_version"), info.get("api_version")))
    except Exception as e:
        print("server: unreachable (%s)" % e)
        return 1
    if not is_admin(api):
        print("admin API: not accessible (set TVH_USER/TVH_PASS)")
        return 2
    anon = [e for e in api.grid("access/entry/grid") if e.get("username", "") in ("", "*") and e.get("admin")]
    print("anonymous admin access: %s" % ("YES (insecure)" if anon else "no"))
    for adtext, fe in find_frontends(api, wait=0):
        p = params_of(fe)
        print("frontend: %s enabled=%s networks=%d" % (fe["text"], p.get("enabled"), len(p.get("networks") or [])))
    for n in api.grid("mpegts/network/grid"):
        print("network: %s muxes=%s services=%s channels=%s scanq=%s" % (
            n.get("networkname"), n.get("num_mux"), n.get("num_svc"), n.get("num_chn"), n.get("scanq_length")))
    muxes = api.grid("mpegts/mux/grid")
    ok = sorted(m["frequency"] // 1000 for m in muxes if m.get("num_svc", 0) > 0)
    print("muxes with services (kHz): %s" % (" ".join(map(str, ok)) or "none"))
    print("channels: %d" % len(api.grid("channel/grid")))
    for s in api.grid("status/subscriptions"):
        print("subscription: %s / %s" % (s.get("title"), s.get("service")))
    for i in api.grid("status/inputs"):
        print("input: %s stream=%s snr=%s signal=%s unc=%s cc=%s" % (
            i.get("input"), i.get("stream"), i.get("snr"), i.get("signal"), i.get("unc"), i.get("cc")))
    return 0


def cmd_viewers(a):
    api = api_from_env(a.url)
    try:
        subs = api.grid("status/subscriptions")
    except Exception:
        print("?")
        return 0
    print(sum(1 for s in subs if str(s.get("title", "")).lower() not in ("scan", "epggrab", "keep")))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:9981")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check-auth")
    c = sub.add_parser("configure")
    c.add_argument("--preset-file", help="dvbv5 scan file (ATSC 8VSB)")
    c.add_argument("--network-name", help="default: '# name:' line of the scan file")
    c.add_argument("--no-scan", action="store_true")
    c.add_argument("--scan-timeout", type=int, default=1800)
    c.add_argument("--map-encrypted", action="store_true")
    sub.add_parser("status")
    sub.add_parser("viewers")
    a = ap.parse_args()
    try:
        return {"check-auth": cmd_check_auth, "configure": cmd_configure,
                "status": cmd_status, "viewers": cmd_viewers}[a.cmd](a) or 0
    except AuthError as e:
        print("error: authentication failed (%s)" % e, file=sys.stderr)
        return 2
    except (urllib.error.URLError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
