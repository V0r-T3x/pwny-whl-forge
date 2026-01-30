#!/bin/bash
# pwny-indexer.sh - Root orchestrator for the pwny-whl-forge
# Fixes: 'basename: missing operand' and improves empty folder handling

BASE_DIR="./profiles"
ROOT_INDEX="./index.html"

echo "--- Starting Precision Forge Indexing ---"

# 1. Initialize Root Index
cat << EOF > "$ROOT_INDEX"
<!DOCTYPE html>
<html>
<head>
    <title>V0rT3x Pwny-Whl-Forge</title>
    <style>
        body { font-family: 'SF Mono', monospace; background: #050505; color: #00ff41; padding: 3rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 20px; margin-top: 40px; }
        .card { border: 1px solid #222; padding: 20px; background: #0a0a0a; border-left: 5px solid #00ff41; }
        .tag { font-size: 0.8rem; background: #1a1a1a; color: #00ff41; padding: 3px 8px; border: 1px solid #333; margin-right: 5px; }
        a { color: inherit; text-decoration: none; }
    </style>
</head>
<body>
    <h1>[ PWNY-WHL-FORGE ]</h1>
    <div class="grid">
EOF

# 2. Iterate through profiles
# Fixed find to be more specific and avoid empty hits
find "$BASE_DIR" -maxdepth 2 -type d -name "wheelhouse" | while read -r WH_PATH; do
    ARCH=$(basename "$(dirname "$WH_PATH")")
    
    # Safely check for wheels before running processing
    WHL_FILES=("$WH_PATH"/*.whl)
    if [ ! -e "${WHL_FILES[0]}" ]; then
        echo "[-] Skipping $ARCH: No .whl files found."
        continue
    fi

    # --- THE PRECISION PARSER ---
    # Extract tags and find the most specific one
    ALL_TAGS=$(ls "$WH_PATH"/*.whl 2>/dev/null | xargs -n1 basename 2>/dev/null | cut -d'-' -f3 | sort -u)
    
    PY_DISPLAY="Unknown"
    RAW_TAG="none"

    for TAG in $ALL_TAGS; do
        if [[ $TAG =~ ^cp([0-9])([0-9][0-9]?)$ ]]; then
            PY_DISPLAY="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            RAW_TAG=$TAG
            break 
        elif [[ $TAG =~ ^py([0-9])$ ]]; then
            if [ "$PY_DISPLAY" == "Unknown" ]; then
                PY_DISPLAY="${BASH_REMATCH[1]}.x"
                RAW_TAG=$TAG
            fi
        fi
    done

    echo "[+] Indexing $ARCH -> Detected Python $PY_DISPLAY ($RAW_TAG)"

    # 3. Generate PEP 503 Sub-Index
    cat << EOF > "$WH_PATH/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Forge: $ARCH</title>
    <style>
        body { font-family: 'SF Mono', monospace; background: #050505; color: #00ff41; padding: 3rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 20px; margin-top: 40px; }
        .card { border: 1px solid #222; padding: 20px; background: #0a0a0a; border-left: 5px solid #00ff41; }
        .tag { font-size: 0.8rem; background: #1a1a1a; color: #00ff41; padding: 3px 8px; border: 1px solid #333; margin-right: 5px; }
        a { color: inherit; text-decoration: none; }
    </style>
</head>
<body>
    <h2>Forge: $ARCH | Python: $PY_DISPLAY</h2>
EOF
    # Safe loop to avoid 'basename' errors on empty lists
    for whl in "$WH_PATH"/*.whl; do
        [ -e "$whl" ] || continue
        WHL_NAME=$(basename "$whl")
        echo "    <a href=\"$WHL_NAME\">$WHL_NAME</a><br>" >> "$WH_PATH/index.html"
    done
    echo "</body></html>" >> "$WH_PATH/index.html"

    # 4. Add to Master Grid
    WEB_LINK=$(echo "$WH_PATH/index.html" | sed 's|^\./||')
    PKG_COUNT=$(find "$WH_PATH" -maxdepth 1 -name "*.whl" | wc -l)
    
    cat << EOF >> "$ROOT_INDEX"
        <div class="card">
            <a href="$WEB_LINK">
                <h3>$ARCH</h3>
                <span class="tag">Python $PY_DISPLAY</span>
                <span class="tag">$RAW_TAG</span>
                <p style="color: #666; font-size: 0.85rem;">Package Count: $PKG_COUNT</p>
            </a>
        </div>
EOF
done

echo "    </div></body></html>" >> "$ROOT_INDEX"
echo "--- Indexing Complete ---"