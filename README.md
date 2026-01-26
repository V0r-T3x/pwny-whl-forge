# pwny-whl-forge

Automated compilation forge for Pwnagotchi dependencies (PyTorch, Torchvision, NumPy, etc.). This project uses Docker on a host machine (Raspberry Pi 4 recommended) to cross-compile or natively build optimized wheels for Pwnagotchi targets (RPi02W, RPi3, RPi4).

## 🏗️ Host Setup (Raspberry Pi 4)

To compile heavy libraries like PyTorch, you need a robust host. A Raspberry Pi 4 (4GB or 8GB) running **Raspberry Pi OS (64-bit Bookworm)** is recommended.

### 1. Prepare Swap Space
Compiling PyTorch requires significant memory during the linking phase. Increase your swap size to 4GB to prevent Out-Of-Memory crashes.

```bash
# Disable the default swap service
sudo dphys-swapfile swapoff

# Edit the config file
sudo nano /etc/dphys-swapfile
```
Ensure these lines are set:
```ini
CONF_SWAPSIZE=4096
CONF_MAXSWAP=4096
```
Apply the changes:
```bash
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
free -m  # Verify you have ~4GB of swap
```

### 2. Install Docker
Install a known-good version of Docker and configure permissions.

```bash
curl -sSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# REBOOT NOW to apply the group change
sudo reboot
```

---

## 🛠️ Compiling Wheels

The forge uses a "Golden" stage-by-stage script to build dependencies in the correct order.

### 1. Build the Docker Base Image
Before running the compile script, ensure you have the builder image ready.

```bash
# From the root of this repository
docker build --platform linux/arm/v7 -t kalibuild:latest -f Dockerfile.build .
```

### 2. Run the Forge
Navigate to the profile matching your target architecture (e.g., `arm32-v7l` for RPi02W/RPi3 running 32-bit OS) and run the compile script.

```bash
cd profiles/arm32-v7l
chmod +x total_compile.sh
./total_compile.sh
```

This script will:
1. Spin up the Docker container.
2. Build NumPy (The Foundation).
3. Build PyTorch (The Brain) with specific ARM optimizations.
4. Build Torchvision and Stable Baselines 3.
5. Output all `.whl` files to the `./wheelhouse` directory.

---

## 📦 Usage (Pip Repository)

You can install the pre-compiled wheels directly from the GitHub Pages repository without building them yourself.

### Example: Installing PyTorch & SB3 (ARM64)

```bash
pip install --extra-index-url https://v0r-t3x.github.io/pwny-whl-forge/profiles/arm64-v8a/wheelhouse/ \
            --trusted-host v0r-t3x.github.io \
            torch torchvision stable-baselines3
```

### Example: Installing for ARMv7l (RPi02W 32-bit)

```bash
pip install --extra-index-url https://v0r-t3x.github.io/pwny-whl-forge/profiles/arm32-v7l/wheelhouse/ \
            --trusted-host v0r-t3x.github.io \
            torch torchvision stable-baselines3
```
