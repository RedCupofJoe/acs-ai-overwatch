#!/usr/bin/env bash
# Install allowlisted recon tools for the Rosey Regrets lab image (UBI9).
set -euo pipefail

dnf install -y --setopt=install_weak_deps=0 \
  nmap nmap-ncat traceroute bind-utils iproute tar gzip unzip curl \
  || dnf install -y --setopt=install_weak_deps=0 \
    nmap nmap-ncat traceroute bind-utils iproute tar gzip unzip curl \
    --enablerepo='*'

install_github_bin() {
  local url="$1"
  local dest="$2"
  curl -fsSL -o /tmp/tool.bin "${url}"
  chmod 0755 /tmp/tool.bin
  mv /tmp/tool.bin "${dest}"
}

# rustscan / naabu / masscan: pin known linux-amd64 release assets.
# If a URL 404s, the image still ships nmap + ncat + dig + traceroute.
set +e
curl -fsSL "https://github.com/projectdiscovery/naabu/releases/download/v2.3.5/naabu_2.3.5_linux_amd64.zip" -o /tmp/naabu.zip \
  && unzip -o /tmp/naabu.zip -d /tmp/naabu \
  && install -m 0755 /tmp/naabu/naabu /usr/local/bin/naabu
curl -fsSL "https://github.com/bee-san/RustScan/releases/download/2.3.0/rustscan-2.3.0-x86_64-linux.zip" -o /tmp/rustscan.zip \
  && unzip -o /tmp/rustscan.zip -d /tmp/rustscan \
  && find /tmp/rustscan -type f -name rustscan -exec install -m 0755 {} /usr/local/bin/rustscan \;
# masscan static-ish binary (falls back to nmap wrapper if missing)
if ! command -v masscan >/dev/null 2>&1; then
  cat >/usr/local/bin/masscan <<'EOF'
#!/usr/bin/env bash
# Lab shim: ACS still sees process name masscan; underlying scan uses nmap when a static masscan is unavailable.
exec nmap -Pn -T4 --max-retries 1 "$@"
EOF
  chmod 0755 /usr/local/bin/masscan
fi
set -e
dnf clean all
rm -rf /var/cache/dnf /tmp/naabu /tmp/rustscan /tmp/*.zip
