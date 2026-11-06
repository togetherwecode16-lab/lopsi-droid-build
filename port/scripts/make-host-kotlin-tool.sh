#!/usr/bin/env bash
# Build a Kotlin host tool by hand and install it where ninja expects it, for tools whose
# Soong install rule is missing from the generated ninja graph.
# Run inside the container: make-host-kotlin-tool.sh <name> <main-class> <src-dir> <src-glob>
set -euo pipefail
NAME="$1" MAIN="$2" SRC="$3" GLOB="$4"
TOP=/aosp
HOST_OUT="$TOP/out/host/linux_musl-arm64"
JDK="$TOP/prebuilts/jdk/jdk21/linux-x86"
M2="$TOP/prebuilts/tools/common/m2/repository"
WORK="$TOP/out/lopsi-host-kotlin/$NAME"
rm -rf "$WORK" && mkdir -p "$WORK/classes"

KC="$M2/org/jetbrains/kotlin/kotlin-compiler-embeddable/2.2.0/kotlin-compiler-embeddable-2.2.0.jar"
DAEMON="$M2/org/jetbrains/kotlin/kotlin-daemon-embeddable/2.2.0/kotlin-daemon-embeddable-2.2.0.jar"
SCRIPT_RT="$M2/org/jetbrains/kotlin/kotlin-script-runtime/2.2.0/kotlin-script-runtime-2.2.0.jar"
REFLECT="$M2/org/jetbrains/kotlin/kotlin-reflect/2.2.0/kotlin-reflect-2.2.0.jar"
TROVE="$M2/org/jetbrains/intellij/deps/trove4j/1.0.20181211/trove4j-1.0.20181211.jar"
COROUTINES="$TOP/prebuilts/cmdline-tools/tools/lib/external/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.9.0/kotlinx-coroutines-core-jvm-1.9.0.jar"
STDLIB="$TOP/prebuilts/cmdline-tools/tools/lib/external/org/jetbrains/kotlin/kotlin-stdlib/2.2.0/kotlin-stdlib-2.2.0.jar"
ANNOT="$M2/org/jetbrains/annotations/13.0/annotations-13.0.jar"
KCP="$KC:$DAEMON:$SCRIPT_RT:$REFLECT:$TROVE:$COROUTINES:$STDLIB:$ANNOT"

# 1. ow2-asm classes (sdkparcelables' static_lib)
ASM="$WORK/asm.jar"
find "$TOP/external/ow2-asm/asm/src/main" -name '*.java' > "$WORK/asm-srcs.txt"
"$JDK/bin/javac" -nowarn -encoding UTF-8 -d "$WORK/asm-classes" @"$WORK/asm-srcs.txt"
"$JDK/bin/jar" --create --file "$ASM" -C "$WORK/asm-classes" .

# 2. Kotlin sources
find "$TOP/$SRC" -name "$GLOB" > "$WORK/srcs.txt"
"$JDK/bin/java" -cp "$KCP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -nowarn -jvm-target 17 -no-stdlib \
  -cp "$ASM:$STDLIB:$ANNOT" \
  -d "$WORK/classes" @"$WORK/srcs.txt"

# 3. Package as executable jar + wrapper
mkdir -p "$HOST_OUT/framework" "$HOST_OUT/bin"
# Bundle the Kotlin runtime so the tool is self-contained
RUNTIME="$WORK/runtime"
mkdir -p "$RUNTIME"
(cd "$RUNTIME" && "$JDK/bin/jar" xf "$STDLIB")
(cd "$RUNTIME" && "$JDK/bin/jar" xf "$ANNOT")
rm -rf "$RUNTIME/META-INF"
cp -r "$RUNTIME/." "$WORK/classes/"
"$JDK/bin/jar" --create --file "$HOST_OUT/framework/$NAME.jar" --main-class "$MAIN" -C "$WORK/classes" .
cat > "$HOST_OUT/bin/$NAME" <<EOF
#!/bin/bash
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$HERE/../../../../prebuilts/jdk/jdk21/linux-x86/bin/java" -jar "\$HERE/../framework/$NAME.jar" "\$@"
EOF
chmod +x "$HOST_OUT/bin/$NAME"
echo "HOST_KOTLIN_TOOL_OK $NAME"