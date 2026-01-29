#!/bin/bash
# total_compile.sh - The "Golden" Stage-by-Stage Forge
WHEELHOUSE_PATH="/work/wheelhouse"
HOST_WHEELHOUSE="$(pwd)/wheelhouse"

# 1. Environment Constraints - Aligned with your "Acid Test" success
export TORCH_VERSION="v2.1.2"    # Bumping to v2.1.2 per your MD notes
export VISION_VERSION="v0.16.0"
export NUMPY_VERSION="1.26.4"
export FLASK="1.1.2"
export ITSDANGEROUS="1.1.0"
export WERKZEUG="2.0.0"
export MAX_JOBS=3               # Keep at 2 to avoid OOM during linking

# Ensure constraints are ready for SB3 and dependencies
cat << EOF > constraints.txt
torch==2.1.0a0+git7bcf7da
numpy<2.0.0
gym==0.21.0
pandas<2.1.0
jinja2==3.0.3
markupsafe==3.0.3
werkzeug==2.0.0
itsdangerous==1.1.0
flask==1.1.2
versioneer
python-dateutil
pytz
EOF

echo "--- Starting Stage-by-Stage System Forge ---"

# Ensure the wheelhouse exists on the host
mkdir -p "$HOST_WHEELHOUSE"

docker run -i --rm \
  --platform linux/arm/v7 \
  -v "$(pwd)":/work \
  -w /work \
  -e MAX_JOBS=$MAX_JOBS \
  -e NUMPY_VERSION=$NUMPY_VERSION \
  -e TORCH_VERSION=$TORCH_VERSION \
  -e VISION_VERSION=$VISION_VERSION \
  kalibuild:latest linux32 /bin/bash << 'EOF'
    WHEELHOUSE_PATH="/work/wheelhouse"
    # FORCE create inside the container to be sure
    mkdir -p "$WHEELHOUSE_PATH"

    # THE FIX: Force Python to identify as armv7l
    export _PYTHON_HOST_PLATFORM="linux-armv7l"
    export PIP_PREFER_BINARY="1"

    set -e # Fail fast if any stage breaks
    export PIP_BREAK_SYSTEM_PACKAGES=1
    
    # Inject missing system headers (Hardening the layer)
    # Includes DBus fix and Atomic ops for ARMv7 linking 
    apt-get update && apt-get install -y \
        git curl build-essential libopenblas-dev libssl-dev \
        libdbus-1-dev pkg-config libglib2.0-dev libatomic-ops-dev libcap-dev \
        cmake ninja-build  libatomic1 libcap-dev patchelf \
        libjpeg-dev libpng-dev zlib1g-dev libavcodec-dev libavformat-dev libswscale-dev

    # --- Phase 1: NumPy (The Foundation) ---
    if [ ! -f "$WHEELHOUSE_PATH/numpy-${NUMPY_VERSION}-cp311-cp311-linux_armv7l.whl" ]; then
      echo "--- Phase 1: Building NumPy ${NUMPY_VERSION} ---"
      python3 -m pip wheel numpy==${NUMPY_VERSION} --wheel-dir=/work/wheelhouse
    fi
    
    # Use a find command to get the exact filename and install it
    NP_WHEEL=$(find "$WHEELHOUSE_PATH" -name "numpy-${NUMPY_VERSION}*.whl" | head -n 1)
    python3 -m pip install "$NP_WHEEL"
    
    # --- Critical build-time deps for PyTorch & Gym ---
    # Instead of installing, we WHEEL them into the wheelhouse first
    # then install from that local folder.
    echo "--- Forging build-time dependencies (cloudpickle, etc) ---"
    python3 -m pip wheel \
        --extra-index-url https://www.piwheels.org/simple \
        --find-links="$WHEELHOUSE_PATH" \
        --wheel-dir="$WHEELHOUSE_PATH" \
        -c /work/constraints.txt \
        pyyaml setuptools wheel typing_extensions "cython<3.0.0" "cloudpickle>=1.2.0" "opencv-python>=3.0"

    # Now install some of them from the wheelhouse you just populated
    python3 -m pip install \
        --no-index \
        --find-links="$WHEELHOUSE_PATH" \
        pyyaml setuptools wheel typing_extensions "cython<3.0.0"

    # --- Phase 1.5: Patching Gym for Python 3.11 ---
    if [ ! -f "$WHEELHOUSE_PATH/gym-0.21.0-py3-none-any.whl" ]; then
      echo "--- Forging Patched Gym 0.21.0 ---"
      curl -L https://github.com/openai/gym/archive/refs/tags/v0.21.0.tar.gz -o gym-v0.21.0.tar.gz
      tar -xzf gym-v0.21.0.tar.gz
      cd gym-0.21.0
      # FIX: The original sed was only touching setup.py; ensure we hit requirements too
      sed -i 's/opencv-python>=3./opencv-python>=3.0/g' setup.py
      find . -name "*.txt" -exec sed -i 's/opencv-python>=3./opencv-python>=3.0/g' {} +
      python3 setup.py bdist_wheel
      cp dist/*.whl $WHEELHOUSE_PATH/
      cd ..
      rm -rf gym-0.21.0* gym-v0.21.0.tar.gz
    fi

    # CRITICAL: Install it NOW so pip stops looking at piwheels for dependencies
    python3 -m pip install --no-cache-dir --no-index --find-links=$WHEELHOUSE_PATH gym==0.21.0

# --- Phase 2: PyTorch ---
    if ls $WHEELHOUSE_PATH/torch-2.1.*.whl 1> /dev/null 2>&1; then
      echo '--- Found Torch wheel, skipping compilation ---'
    else
      echo "--- Phase 2: Compiling PyTorch $TORCH_VERSION ---"
      [ ! -d "pytorch" ] && git clone --branch $TORCH_VERSION --depth 1 --recursive https://github.com/pytorch/pytorch.git
      cd pytorch
      
      rm -rf build
      
      # SURGICAL PATCH: Neuter AArch64 detection in cpuinfo
      # This stops the compiler from looking for 'bf16' or 'sve' members
      find third_party/cpuinfo -name "*.c" -exec sed -i 's/defined(__aarch64__)/0/g' {} +
      find third_party/cpuinfo -name "*.h" -exec sed -i 's/defined(__aarch64__)/0/g' {} +

      export ARCH=armv7l
      export CFLAGS="-O2 -mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
      export CXXFLAGS="-O2 -mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
      export LDFLAGS="-latomic"
      
      # Ensure MAX_JOBS is set for the internal build
      export MAX_JOBS=4 

      # Full module shutdown to prevent dependency leaks
      export USE_CUDA=0 USE_DISTRIBUTED=0 BUILD_TEST=0 USE_MKLDNN=0 \
             USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 \
             USE_XNNPACK=0 USE_CPUINFO=OFF USE_SYSTEM_CPUINFO=OFF \
             USE_NATIVE_ARCH=OFF INTERN_BUILD_MOBILE=0 \
             USE_TBB=OFF USE_KINETO=OFF USE_FBGEMM=OFF

      python3 setup.py bdist_wheel
      
      cp dist/*.whl $WHEELHOUSE_PATH/
      cd /work
    fi

    # --- Vault Population: Harvest dependencies ---
    echo "--- Populating Wheelhouse with dependencies ---"
    python3 -m pip wheel --wheel-dir=$WHEELHOUSE_PATH \
        --extra-index-url https://www.piwheels.org/simple \
        -c constraints.txt \
        "$WHEELHOUSE_PATH"/torch-*.whl "$WHEELHOUSE_PATH"/gym-*.whl stable-baselines3==1.8.0

    # Install the Golden Wheel from the local vault
    python3 -m pip install --no-index --find-links=$WHEELHOUSE_PATH \
        $WHEELHOUSE_PATH/torch-*.whl

    # --- Phase 3: Torchvision ---
    if ls $WHEELHOUSE_PATH/torchvision-0.16.0*.whl 1> /dev/null 2>&1; then
      echo '--- Found Torchvision wheel, skipping ---'
    else
      echo "--- Phase 3: Compiling Torchvision $VISION_VERSION ---"
      [ ! -d "vision" ] && git clone --branch $VISION_VERSION --depth 1 https://github.com/pytorch/vision
      cd vision
      export BUILD_VERSION=0.16.0
      # Reuse the architecture flags from Phase 2
      python3 setup.py bdist_wheel
      cp dist/*.whl $WHEELHOUSE_PATH/
      cd /work
    fi

    # --- Phase 3.5: Stable Baselines 3 ---
    echo '--- Phase 3.5: Building Stable Baselines 3 ---'
    python3 -m pip wheel stable-baselines3==1.8.0 \
      -c constraints.txt \
      --no-build-isolation \
      --find-links=/work/wheelhouse \
      --wheel-dir=/work/wheelhouse

    # --- Phase 4: Final Assembly (The 0.29 Compatibility Fix) ---
    echo '--- Phase 4: Building remaining requirements ---'

    # 1. Identify your specific forged wheels (Ensures pip sees the exact local file)
    TORCH_WHEEL=$(find "$WHEELHOUSE_PATH" -name "torch-2.1.0*.whl" | head -n 1)
    VISION_WHEEL=$(find "$WHEELHOUSE_PATH" -name "torchvision-0.16.0*.whl" | head -n 1)
    GYM_WHEEL=$(find "$WHEELHOUSE_PATH" -name "gym-0.21.0*.whl" | head -n 1)

    # 2. THE LOCAL LOCKDOWN: Resolve AI Stack first (No Index)
    # We include numpy<2.0.0 here to lock the resolver's state
    echo "--- Locking AI Stack and NumPy < 2.0.0 ---"
    python3 -m pip wheel \
      --wheel-dir=$WHEELHOUSE_PATH \
      --find-links=$WHEELHOUSE_PATH \
      --no-index \
      "$TORCH_WHEEL" \
      "$VISION_WHEEL" \
      "$GYM_WHEEL" \
      "numpy<2.0.0" \
      stable-baselines3==1.8.0

    # 3. THE GENERAL HARVEST: Filter out what we just locked
    # This prevents pip from reconsidering them and going online for 2.4.1
    grep -vE "gym|torch|stable-baselines3" /work/build-requirements.txt > /tmp/general-reqs.txt

    echo "--- Harvesting remaining system requirements ---"
    python3 -m pip wheel -r /tmp/general-reqs.txt \
      --wheel-dir=$WHEELHOUSE_PATH \
      --find-links=$WHEELHOUSE_PATH \
      --no-build-isolation \
      --extra-index-url https://www.piwheels.org/simple \
      -c /work/constraints.txt
EOF