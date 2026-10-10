#!/bin/sh
# Build Firefox package for copper-pages / ingot
# Downloads Mozilla's official pre-built Firefox, stages it, creates tarball,
# computes sha256, and updates the package JSON.

set -eu

# Configuration
FIREFOX_VERSION="157.0.1"
FIREFOX_PKG_VERSION="${FIREFOX_VERSION}-1"
CATEGORY="tools"
PACKAGE="firefox"

# Mozilla's official Linux x86_64 tarball URL (en-US)
# Primary: download.mozilla.org (current recommended)
# Fallback: archive.mozilla.org
MOZILLA_URL_PRIMARY="https://download.mozilla.org/?product=firefox-${FIREFOX_VERSION}-SSL&os=linux64&lang=en-US"
MOZILLA_URL_FALLBACK="https://archive.mozilla.org/pub/firefox/releases/${FIREFOX_VERSION}/linux-x86_64/en-US/firefox-${FIREFOX_VERSION}.tar.bz2"

# Paths
WORKDIR="${PWD}/firefox-pkg-work"
STAGING="${WORKDIR}/staging"
TARBALL_NAME="${PACKAGE}-${FIREFOX_PKG_VERSION}.tar.gz"
TARBALL_PATH="${WORKDIR}/${TARBALL_NAME}"

# copper-ingot-repo repo path (where the package JSON lives)
# Updated: 12hrformat/copper-pages renamed to 12hrformat/copper-ingot-repo
COPPER_PAGES="${PWD}/../copper-ingot-repo"
# or could be at the temp location
if [ ! -d "${COPPER_PAGES}" ]; then
    COPPER_PAGES="/mnt/c/Users/dragon/AppData/Local/Temp/opencode/copper-ingot-repo"
fi

PKG_JSON="${COPPER_PAGES}/iso/copper/pkg/${CATEGORY}/${PACKAGE}"

echo "=== Building Firefox package ==="
echo "Version: ${FIREFOX_PKG_VERSION}"
echo "Work dir: ${WORKDIR}"
echo "Package JSON: ${PKG_JSON}"

# Clean and create work directory
rm -rf "${WORKDIR}"
mkdir -p "${STAGING}/usr/lib" "${STAGING}/usr/bin" "${STAGING}/usr/share/applications" "${STAGING}/usr/share/icons/hicolor"

# Download Firefox from Mozilla
echo "Downloading Firefox from Mozilla..."
cd "${WORKDIR}"
DOWNLOAD_FILE="firefox-${FIREFOX_VERSION}.tar.bz2"

# Try primary URL first
wget --show-progress -O "${DOWNLOAD_FILE}" "${MOZILLA_URL_PRIMARY}" || {
    echo "Primary URL failed, trying fallback..."
    wget --show-progress -O "${DOWNLOAD_FILE}" "${MOZILLA_URL_FALLBACK}" || {
        echo "ERROR: Failed to download Firefox from both URLs"
        exit 1
    }
}

# Verify download
if [ ! -f "${DOWNLOAD_FILE}" ]; then
    echo "ERROR: Download file not created: ${DOWNLOAD_FILE}"
    echo "Directory contents:"
    ls -la
    exit 1
fi

FILE_SIZE=$(stat -c%s "${DOWNLOAD_FILE}")
if [ "${FILE_SIZE}" -lt 1000000 ]; then
    echo "ERROR: Download file too small (${FILE_SIZE} bytes) - likely an error page"
    echo "First 200 bytes:"
    head -c 200 "${DOWNLOAD_FILE}"
    echo ""
    exit 1
fi

# Detect file type and extract accordingly
echo "Detecting archive format..."
FILE_TYPE=$(file -b "${DOWNLOAD_FILE}")
echo "Downloaded file type: ${FILE_TYPE}"

if echo "${FILE_TYPE}" | grep -q "bzip2"; then
    echo "Extracting as bzip2..."
    tar -xjf "${DOWNLOAD_FILE}" -C "${STAGING}/usr/lib"
elif echo "${FILE_TYPE}" | grep -q "XZ"; then
    echo "Extracting as XZ..."
    tar -xJf "${DOWNLOAD_FILE}" -C "${STAGING}/usr/lib"
elif echo "${FILE_TYPE}" | grep -q "gzip"; then
    echo "Extracting as gzip..."
    tar -xzf "${DOWNLOAD_FILE}" -C "${STAGING}/usr/lib"
elif echo "${FILE_TYPE}" | grep -q "tar archive"; then
    echo "Extracting as plain tar..."
    tar -xf "${DOWNLOAD_FILE}" -C "${STAGING}/usr/lib"
else
    echo "ERROR: Unknown archive format: ${FILE_TYPE}"
    echo "First 100 bytes:"
    head -c 100 "${DOWNLOAD_FILE}" | xxd
    exit 1
fi

# The extracted directory is just "firefox"
mv "${STAGING}/usr/lib/firefox" "${STAGING}/usr/lib/firefox-${FIREFOX_VERSION}"

# Create symlink for version-agnostic access
ln -sf "firefox-${FIREFOX_VERSION}" "${STAGING}/usr/lib/firefox"

# Create /usr/bin/firefox wrapper script
cat > "${STAGING}/usr/bin/firefox" <<'EOF'
#!/bin/sh
# Firefox launcher for Copper Linux
# Uses the bundled libraries in /usr/lib/firefox
exec /usr/lib/firefox/firefox "$@"
EOF
chmod +x "${STAGING}/usr/bin/firefox"

# Create .desktop file
cat > "${STAGING}/usr/share/applications/firefox.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Firefox Web Browser
Comment=Browse the World Wide Web
GenericName=Web Browser
Exec=firefox %u
Terminal=false
X-MultipleArgs=false
Type=Application
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;
StartupNotify=true
EOF

# Copy Firefox's default icon to hicolor
if [ -f "${STAGING}/usr/lib/firefox-${FIREFOX_VERSION}/browser/chrome/icons/default/default128.png" ]; then
    mkdir -p "${STAGING}/usr/share/icons/hicolor/128x128/apps"
    cp "${STAGING}/usr/lib/firefox-${FIREFOX_VERSION}/browser/chrome/icons/default/default128.png" \
       "${STAGING}/usr/share/icons/hicolor/128x128/apps/firefox.png"
fi

# Also copy 48x48 and 64x64 if available
for size in 16 32 48 64; do
    if [ -f "${STAGING}/usr/lib/firefox-${FIREFOX_VERSION}/browser/chrome/icons/default/default${size}.png" ]; then
        mkdir -p "${STAGING}/usr/share/icons/hicolor/${size}x${size}/apps"
        cp "${STAGING}/usr/lib/firefox-${FIREFOX_VERSION}/browser/chrome/icons/default/default${size}.png" \
           "${STAGING}/usr/share/icons/hicolor/${size}x${size}/apps/firefox.png"
    fi
done

# Create the final tarball (contents extract relative to /)
echo "Creating package tarball..."
cd "${STAGING}"
tar -czf "${TARBALL_PATH}" usr

echo "Verifying tarball contents:"
tar -tzf "${TARBALL_PATH}" | head -30

# Compute sha256
echo "Computing sha256..."
SHA256=$(sha256sum "${TARBALL_PATH}" | awk '{print $1}')
echo "sha256: ${SHA256}"

# Update the package JSON with the correct sha256
echo "Updating package JSON..."
cat > "${PKG_JSON}" <<EOF
{
  "name": "${PACKAGE}",
  "version": "${FIREFOX_PKG_VERSION}",
  "category": "${CATEGORY}",
  "url": "https://github.com/12hrformat/copper-ingot-repo/releases/download/payloads-v1/${TARBALL_NAME}",
  "sha256": "${SHA256}",
  "depends": []
}
EOF

echo ""
echo "=== Package built successfully ==="
echo "Tarball: ${TARBALL_PATH}"
echo "SHA256:  ${SHA256}"
echo "Package JSON updated: ${PKG_JSON}"
echo ""
echo "NEXT STEPS:"
echo "1. Upload the tarball to GitHub Releases:"
echo "   gh release create payloads-v1 ${TARBALL_PATH} --repo 12hrformat/copper-ingot-repo"
echo "   (or if release exists: gh release upload payloads-v1 ${TARBALL_PATH} --repo 12hrformat/copper-ingot-repo)"
echo ""
echo "2. Verify the release URL works:"
echo "   https://github.com/12hrformat/copper-ingot-repo/releases/download/payloads-v1/${TARBALL_NAME}"
echo ""
echo "3. Push the updated package JSON to copper-ingot-repo:"
echo "   cd ${COPPER_PAGES}"
echo "   git add iso/copper/pkg/${CATEGORY}/${PACKAGE}"
echo "   git commit -m \"firefox: update sha256 for ${FIREFOX_PKG_VERSION}\""
echo "   git push"
echo ""
echo "4. Test in Copper ISO:"
echo "   sudo ingot install firefox"