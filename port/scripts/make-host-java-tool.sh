#!/usr/bin/env bash
# Build a host java tool by hand and install it where ninja expects it, for tools whose
# Soong install rule is missing (their deps live in parked/absent projects).
# Run inside the container: make-host-java-tool.sh <name> <main-class> <src-dir> [classpath-jar ...]
set -euo pipefail
NAME="$1" MAIN="$2" SRC="$3"; shift 3
TOP=/aosp
HOST_OUT="$TOP/out/host/linux_musl-arm64"
JDK="$TOP/prebuilts/jdk/jdk21/linux-x86"
WORK="$TOP/out/lopsi-host-java/$NAME"
rm -rf "$WORK" && mkdir -p "$WORK/classes"
CP=$(IFS=:; echo "$*")
find "$TOP/$SRC" -name '*.java' > "$WORK/srcs.txt"
"$JDK/bin/javac" -nowarn -encoding UTF-8 ${CP:+-cp "$CP"} -d "$WORK/classes" @"$WORK/srcs.txt"
for j in "$@"; do (cd "$WORK/classes" && "$JDK/bin/jar" xf "$j"); done
rm -rf "$WORK/classes/META-INF"
mkdir -p "$HOST_OUT/framework" "$HOST_OUT/bin"
"$JDK/bin/jar" --create --file "$HOST_OUT/framework/$NAME.jar" --main-class "$MAIN" -C "$WORK/classes" .
cat > "$HOST_OUT/bin/$NAME" <<EOF
#!/bin/bash
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$HERE/../../../../prebuilts/jdk/jdk21/linux-x86/bin/java" -jar "\$HERE/../framework/$NAME.jar" "\$@"
EOF
chmod +x "$HOST_OUT/bin/$NAME"
echo "HOST_JAVA_TOOL_OK $NAME"
