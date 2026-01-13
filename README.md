# pukaipu
pukaipu is a secure, per-user remote browser + terminal environment built on Xpra, Qtile, and Brave, designed to run multiple isolated instances on a single host — one container per user.

Each instance:
	•	runs under its own Unix user (UID 3000–4000 range)
	•	exposes a browser-based desktop over HTTPS/WebSocket
	•	uses client-certificate authentication
	•	is hardened with seccomp + AppArmor
	•	persists user state in the user’s host home directory

⸻

Features
	•	🔒 Strong isolation
Per-user UID/GID, seccomp profile, AppArmor profile.
	•	🧑‍💻 One user = one container
Clean mapping: /home/<user> → /data/home inside container.
	•	🌐 Remote browser desktop
Brave + Qtile streamed via Xpra HTML5 client.
	•	🧾 Client certificate auth
Self-signed root CA, per-user client cert (client.p12).
	•	🔁 Reproducible builds
docker compose up --build always rebuilds from the repo.
	•	🛠 Idempotent provisioning
Running the setup script twice does not overwrite existing instances.

⸻

Requirements
	•	Linux host (tested on Debian)
	•	Docker or Podman
	•	AppArmor enabled
	•	Root access (for user creation & profiles)

⸻

Quick start

Clone the repo to a central location on the host:

git clone https://github.com/scuq/pukaipu.git
cd pukaipu

Create a new user instance:

sudo ./create-instance.sh john --fqdn john.example.org

Start it:

cd /opt/pukaipu/john
docker compose up -d --build

Open in browser:

https://john.example.org:<assigned-port>

Import the generated client certificate (client.p12) into your browser
→ the passphrase is printed once on first startup.

⸻

Directory layout

/opt/pukaipu/
└── john/
    ├── docker-compose.yml
    ├── seccomp_chrome.json
    ├── seccomp_log.json
    └── certs/
        ├── ca.crt
        ├── server.crt
        ├── server.key
        └── client.p12

User data lives in:

/home/john/
├── .config/qtile
├── .config/kitty
├── .cache
└── brave-profile


⸻

Security model (high level)
	•	Container runs as non-root user
	•	No shared volumes between users
	•	Client cert required to connect
	•	seccomp restricts syscalls (Chrome-aware)
	•	AppArmor profile allows user namespaces but blocks everything else

⸻

What this is (and isn’t)

✅ Great for:
	•	secure remote browsing
	•	admin jump environments
	•	sandboxed access to untrusted sites
	•	per-user ephemeral desktops

❌ Not intended as:
	•	a multi-user desktop inside one container
	•	a full VDI replacement
	•	a Wayland-native environment (Xpra/X11-based)
