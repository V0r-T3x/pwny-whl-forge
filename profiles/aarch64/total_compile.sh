#!/bin/bash
# total_compile.sh - The "Golden" Stage-by-Stage Forge
WHEELHOUSE_PATH="/work/wheelhouse"
HOST_WHEELHOUSE="$(pwd)/wheelhouse"

# 1. Environment Constraints - Aligned with your "Acid Test" success
export TORCH_VERSION="v2.1.2"    # Reverting to the tag that produced your Golden Wheel
export VISION_VERSION="v0.16.0"
export NUMPY_VERSION="1.26.4"
export FLASK="1.1.2"
export ITSDANGEROUS="1.1.0"
export WERKZEUG="2.0.0"
export MAX_JOBS=4               # Keep at 2 to avoid OOM during linking
export _PYTHON_HOST_PLATFORM="linux-aarch64"

# Ensure constraints are ready for SB3 and dependencies
cat << EOF > constraints.txt
numpy<2.0.0
pandas<2.1.0
markupsafe>=2.0.1
gym==0.21
torch==2.1.0a0+gita8e7c98
jinja2==3.0.3
click==7.1.2
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
  --platform linux/arm64 \
  -v "$(pwd)":/work \
  -w /work \
  -e MAX_JOBS=$MAX_JOBS \
  -e NUMPY_VERSION=$NUMPY_VERSION \
  -e TORCH_VERSION=$TORCH_VERSION \
  -e VISION_VERSION=$VISION_VERSION \
  kalibuild:latest-64 /bin/bash << 'EOF'
    WHEELHOUSE_PATH="/work/wheelhouse"
    # FORCE create inside the container to be sure
    mkdir -p "$WHEELHOUSE_PATH"

    # THE FIX: Force Python to identify as armv8l
    export _PYTHON_HOST_PLATFORM="linux-aarch64"
    export PIP_PREFER_BINARY="1"

    set -e # Fail fast if any stage breaks
    export PIP_BREAK_SYSTEM_PACKAGES=1
    
    # Clean up conflicting/duplicate wheels from previous runs
    # rm -f "$WHEELHOUSE_PATH"/torch-2.1.0a0*.whl # KEEP your existing Golden Wheel
    #rm -f "$WHEELHOUSE_PATH"/MarkupSafe-2.1.5*.whl
    #rm -f "$WHEELHOUSE_PATH"/gym-0.21.0*.whl # Force rebuild of Gym to fix metadata
    #rm -f "$WHEELHOUSE_PATH"/torchvision-0.16.0*.whl # Force rebuild to apply dependency patch

    # Inject missing system headers (Hardening the layer)
    # Includes DBus fix and Atomic ops for ARMv8 linking 
    apt-get update && apt-get install -y \
        git curl build-essential libopenblas-dev libssl-dev \
        libdbus-1-dev pkg-config libglib2.0-dev libatomic-ops-dev \
        cmake ninja-build libatomic1 libcap-dev patchelf \
        libjpeg-dev libpng-dev zlib1g-dev libavcodec-dev libavformat-dev libswscale-dev

    # --- Phase 1: NumPy (The Foundation) ---
    if [ ! -f "$WHEELHOUSE_PATH/numpy-${NUMPY_VERSION}-cp311-cp311-aarch64.whl" ]; then
      echo "--- Phase 1: Building NumPy ${NUMPY_VERSION} ---"
      python3 -m pip wheel numpy==${NUMPY_VERSION} --wheel-dir=/work/wheelhouse
    fi
    
    # Use a find command to get the exact filename and install it
    NP_WHEEL=$(find "$WHEELHOUSE_PATH" -name "numpy-${NUMPY_VERSION}*.whl" | head -n 1)
    python3 -m pip install "$NP_WHEEL"
    
    # --- Critical build-time deps for PyTorch ---
    # Instead of installing, we WHEEL them into the wheelhouse first
    # then install from that local folder.
    echo "--- Forging build-time dependencies ---"
    python3 -m pip wheel \
        --find-links="$WHEELHOUSE_PATH" \
        --wheel-dir="$WHEELHOUSE_PATH" \
        pyyaml setuptools wheel typing_extensions "cython<3.0.0" "cloudpickle>=1.2.0"

    # Now install them from the wheelhouse you just populated
    python3 -m pip install \
        --no-index \
        --find-links="$WHEELHOUSE_PATH" \
        pyyaml setuptools typing_extensions "cython<3.0.0"

    # --- Phase 1.5: Patching Gym for Python 3.11 ---
    if [ ! -f "$WHEELHOUSE_PATH/gym-0.21.0-py3-none-any.whl" ]; then
      echo "--- Forging Patched Gym 0.21.0 ---"
      curl -L https://github.com/openai/gym/archive/refs/tags/v0.21.0.tar.gz -o gym-v0.21.0.tar.gz
      tar -xzf gym-v0.21.0.tar.gz
      cd gym-0.21.0
      sed -i 's/opencv-python>=3./opencv-python>=3.0/g' setup.py
      python3 setup.py bdist_wheel
      cp dist/*.whl $WHEELHOUSE_PATH/
      cd ..
      rm -rf gym-0.21.0* gym-v0.21.0.tar.gz
    fi

    # CRITICAL: Install it NOW so pip stops looking at piwheels
    python3 -m pip install --no-cache-dir --no-index --find-links=$WHEELHOUSE_PATH gym==0.21.0

# --- Phase 2: PyTorch ---
    if ls $WHEELHOUSE_PATH/torch-2.1.*.whl 1> /dev/null 2>&1; then
      echo '--- Found Torch wheel, skipping compilation ---'
    else
      echo "--- Phase 2: Compiling PyTorch $TORCH_VERSION ---"
      if [ ! -d "pytorch" ]; then
        git clone --recursive https://github.com/pytorch/pytorch.git
        cd pytorch
        git checkout $TORCH_VERSION
      else
        cd pytorch
        # SURGICAL STRIKE: Remove any stale git locks from previous failed runs
        echo "--- Clearing stale git locks ---"
        find .git -name "index.lock" -delete
      fi
      git submodule sync
      git submodule update --init --recursive --jobs $MAX_JOBS
      
      rm -rf build
      
      # SURGICAL PATCH: Neuter AArch64 detection in cpuinfo
      # This stops the compiler from looking for 'bf16' or 'sve' members
      #find third_party/cpuinfo -name "*.c" -exec sed -i 's/defined(__aarch64__)/0/g' {} +
      #find third_party/cpuinfo -name "*.h" -exec sed -i 's/defined(__aarch64__)/0/g' {} +

      export ARCH=aarch64
      export PYTORCH_BUILD_VERSION=2.1.0
      export PYTORCH_BUILD_NUMBER=0
      export CFLAGS="-O2 -mcpu=cortex-a53"
      export CXXFLAGS="-O2 -mcpu=cortex-a53"
      export LDFLAGS=""
      
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

    for f in "$WHEELHOUSE_PATH"/torch-2.1.0a0*.whl; do
        if [ -e "$f" ]; then
            new_name="$f"
            new_name="${new_name/linux_aarch64/manylinux_2_17_aarch64.manylinux2014_aarch64}"
            if [ "$f" != "$new_name" ]; then
                mv "$f" "$new_name"
            fi
        fi
    done

    # --- Vault Population: Harvest dependencies ---
    echo "--- Populating Wheelhouse with dependencies ---"
    # Unified the command to avoid comment-breakage
    python3 -m pip wheel --wheel-dir=$WHEELHOUSE_PATH \
        --extra-index-url https://www.piwheels.org/simple \
        -c /work/constraints.txt \
        --extra-index-url https://www.piwheels.org/simple \
        "$WHEELHOUSE_PATH"/torch-2.1*.whl "$WHEELHOUSE_PATH"/gym-0.21*.whl \
        stable-baselines3==1.8.0

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
      # SURGICAL PATCH: Relax dependency to accept your alpha torch wheel
      # Change 'torch==2.1.0' to just 'torch' to allow our alpha/renamed wheel
      sed -i 's/torch==[0-9.]*/torch/g' setup.py
      sed -i "s/'torch==' + .*/'torch',/g" setup.py
      sed -i 's/torch==[0-9.]*/torch/g' requirements.txt 2>/dev/null || true
      sed -i -E 's/torch(==|>=)[0-9.]+/torch/g' setup.py
      sed -i -E "s/torch(==|>=)[0-9.]+/torch/g" setup.py
      sed -i -E 's/torch(==|>=)[0-9.]+/torch/g' requirements.txt 2>/dev/null || true
      export BUILD_VERSION=0.16.0
      # Reuse the architecture flags from Phase 2
      python3 setup.py bdist_wheel
      cp dist/*.whl $WHEELHOUSE_PATH/

      # FIX: Rename torchvision to manylinux to match torch and prevent pip from preferring PyPI
      for f in "$WHEELHOUSE_PATH"/torchvision-0.16.0*.whl; do
        if [ -e "$f" ]; then
            new_name="$f"
            new_name="${new_name/linux_aarch64/manylinux_2_17_aarch64.manylinux2014_aarch64}"
            if [ "$f" != "$new_name" ]; then
                mv "$f" "$new_name"
            fi
        fi
      done
      cd /work
    fi

    # --- Phase 3.5: Stable Baselines 3 ---
    echo '--- Phase 3.5: Building Stable Baselines 3 ---'
    python3 -m pip wheel stable-baselines3==1.8.0 \
      -c constraints.txt \
      --no-build-isolation \
      --find-links=/work/wheelhouse \
      --wheel-dir=/work/wheelhouse

    # --- Phase 4: Final Assembly (The "Literal" Forge) ---
    echo '--- Phase 4: Building remaining requirements ---'

    # 1. Identify your specific forged wheels (Ensures pip sees the exact local file)
    TORCH_WHEEL=$(find "$WHEELHOUSE_PATH" -name "torch-2.1.0*.whl" | head -n 1)
    VISION_WHEEL=$(find "$WHEELHOUSE_PATH" -name "torchvision-0.16.0*.whl" | head -n 1)
    GYM_WHEEL=$(find "$WHEELHOUSE_PATH" -name "gym-0.21.0*.whl" | head -n 1)

    # 2. THE LOCAL LOCKDOWN: Resolve SB3 using literal paths
    # This forces pip to recognize your custom git-build IS 'torch' and uses your patched gym
    echo "--- Forcing SB3 resolution against local wheels ---"
    python3 -m pip wheel \
      --wheel-dir=$WHEELHOUSE_PATH \
      --find-links=$WHEELHOUSE_PATH \
      --no-index \
      "$TORCH_WHEEL" \
      "$VISION_WHEEL" \
      "$GYM_WHEEL" \
      stable-baselines3==1.8.0

    # 3. THE GENERAL HARVEST: Filter AI stack to avoid piwheels metadata errors
    grep -vE "gym|torch|stable-baselines3" /work/build-requirements.txt > /tmp/general-reqs.txt

    echo "--- Harvesting remaining system requirements ---"
    python3 -m pip wheel -r /tmp/general-reqs.txt \
      --wheel-dir=$WHEELHOUSE_PATH \
      --find-links=$WHEELHOUSE_PATH \
      --extra-index-url https://www.piwheels.org/simple \
      -c /work/constraints.txt
EOF