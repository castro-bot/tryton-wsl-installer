# Tryton WSL Installer

Zero-interaction, idempotent installer for **Tryton** (`trytond` + `tryton-sao` web client + PostgreSQL) on **Windows WSL (Ubuntu / Debian)**.

- **100% non-interactive** by default — no menus, no `apt` prompts, no `trytond-admin` password prompts.
- **Defaults to Tryton `7.2`**, easily switchable to **`latest`** (currently `8.2.x`) or any series with one variable.
- **PostgreSQL inside WSL by default** (auto-installed if missing) and ready for Windows clients (**pgAdmin**, **DBeaver**, **DataGrip**) on `localhost:5432`.
- Supports connecting to an **external or Windows-hosted PostgreSQL server** via `PG_HOST`.

---

## Quick Start (One-Liners)

### From WSL (Ubuntu / Debian terminal)

```bash
curl -fsSL https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh | bash
```

### From Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex
```

After installation completes:

```bash
# Start Tryton server
~/tryton/start.sh

# View generated Tryton admin & PostgreSQL credentials (chmod 600)
cat ~/tryton/.credentials
```

Then open **http://localhost:8000** in your Windows browser.

---

## Common Overrides

### Install the latest Tryton version (instead of `7.2`)

**WSL Bash:**
```bash
curl -fsSL https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh | TRYTON_SERIES=latest bash
```

**Windows PowerShell:**
```powershell
$env:TRYTON_SERIES = "latest"; irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex
```

You can also pin any specific series (e.g. `TRYTON_SERIES=7.6` or `TRYTON_SERIES=8.2`). The installer automatically handles both `bower_components` (Tryton `7.x`) and `node_modules` (Tryton `8.x+`) for `tryton-sao`.

### Use an external or Windows-hosted PostgreSQL server

If you already run PostgreSQL on Windows or another host and do not want PostgreSQL installed inside WSL, pass `PG_HOST` and `PG_PASSWORD`:

```bash
curl -fsSL https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh | \
  PG_HOST=192.168.1.10 PG_PORT=5432 PG_USER=postgres PG_DB=tryton PG_PASSWORD=yourpassword bash
```

### Connect from Windows PostgreSQL clients (pgAdmin, DBeaver, DataGrip)

When using the default local WSL PostgreSQL mode, WSL2 automatically forwards `localhost:5432` to Windows. Use the values from `cat ~/tryton/.credentials`:

| Setting | Default |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `tryton` |
| User | `tryton` |
| Password | Auto-generated in `~/tryton/.credentials` (or your `PG_PASSWORD`) |

---

## Configuration Variables

| Variable | Default | Description |
|---|---|---|
| `TRYTON_SERIES` | `7.2` | Tryton series (`7.2`, `8.2`, or `latest`) |
| `INSTALL_DIR` | `~/tryton` | Directory for `.venv`, `tryton-sao`, `trytond.conf`, and helper scripts |
| `DATA_DIR` | `~/db` | Tryton filestore directory |
| `TRYTON_PORT` | `8000` | Port on `localhost` for Tryton & `sao` |
| `TRYTON_ADMIN_EMAIL` | `admin@localhost` | Admin email configured by `trytond-admin` |
| `TRYTON_ADMIN_PASSWORD` | *(auto-generated)* | Admin password (stored in `~/.credentials` with `chmod 600`) |
| `TRYTON_LANG` | *(empty)* | Optional language code to load (e.g. `es`, `fr`) |
| `TRYTON_EXTRA_MODULES` | *(empty)* | Optional space-separated `trytond_*` packages to install |
| `PG_HOST` | *(empty = local WSL)* | Set to skip local PostgreSQL install and connect externally |
| `PG_PORT` | `5432` | PostgreSQL port |
| `PG_USER` | `tryton` | PostgreSQL username (least-privilege role in local mode) |
| `PG_DB` | `tryton` | PostgreSQL database name |
| `PG_PASSWORD` | *(auto-generated)* | PostgreSQL password (required if `PG_HOST` is set) |
| `SKIP_APT` | `0` | Set to `1` to skip `apt-get` calls |
| `DRY_RUN` | `0` | Set to `1` (or `--dry-run`) to validate without making changes |

---

## Testing Safely Before Pushing (Throwaway WSL Distro)

1. In Windows PowerShell, install or import a separate Ubuntu distro (e.g. `Ubuntu-22.04`):
   ```powershell
   wsl --install -d Ubuntu-22.04
   ```
   *(Finish creating the Linux username/password in the new window, then close it.)*

2. Run `install-wsl.ps1` pointing to that throwaway distro and your local `install.sh`:
   ```powershell
   \\wsl.localhost\Ubuntu\home\a\code\tryton-wsl-installer\install-wsl.ps1 `
     -Distro Ubuntu-22.04 `
     -LocalScript \\wsl.localhost\Ubuntu\home\a\code\tryton-wsl-installer\install.sh `
     -TrytonPort 8001 `
     -StartServer
   ```
   *(Use `-TrytonPort 8001` if port `8000` is in use, or `-PgPort 5433` if your primary WSL Ubuntu already has PostgreSQL listening on `5432`.)*

3. Open **http://localhost:8001** in your browser and verify Tryton `sao` loads and logs in with the credentials in `~/tryton/.credentials`.

4. Remove the throwaway distro when done:
   ```powershell
   wsl --unregister Ubuntu-22.04
   ```
