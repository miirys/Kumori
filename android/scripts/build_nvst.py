#!/usr/bin/env python3
"""Build the NVST JNI library (android/nvst) for the ARM ABIs TV boxes use. No downloads of binaries."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

NDK_VERSION = '27.2.12479018'
root = Path(__file__).resolve().parents[1] / 'nvst'


def find_ndk():
    """The NDK given on the command line, else the one the Android SDK holds."""
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    for name in ('ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT'):
        if os.environ.get(name):
            return Path(os.environ[name])
    sdks = [os.environ.get('ANDROID_SDK_ROOT'), os.environ.get('ANDROID_HOME')]
    properties = root.parent / 'local.properties'
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith('sdk.dir='):
                sdks.append(line.split('=', 1)[1].strip().replace('\\:', ':').replace('\\\\', '\\'))
    sdks += [str(Path.home() / 'Library/Android/sdk'), str(Path.home() / 'Android/Sdk')]
    for sdk in sdks:
        if sdk and (Path(sdk) / 'ndk' / NDK_VERSION).is_dir():
            return Path(sdk) / 'ndk' / NDK_VERSION
    raise SystemExit(
        f'NDK {NDK_VERSION} not found. Install it with the Android SDK Manager, or run:\n'
        '  python3 scripts/build_nvst.py /path/to/ndk [output folder]'
    )


ndk = find_ndk()
if not ndk.is_dir():
    raise SystemExit(f'No NDK at {ndk}')
output = Path(sys.argv[2]) if len(sys.argv) > 2 else root.parent / 'app/src/main/jniLibs'
host = {'Darwin': 'darwin-x86_64', 'Linux': 'linux-x86_64', 'Windows': 'windows-x86_64'}[platform.system()]
toolchain = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
cargo = os.environ.get('CARGO') or shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
cmake = os.environ.get('CMAKE')
if not cmake:
    # Prefer the SDK copy so a Visual Studio developer shell cannot silently select
    # its host CMake for an Android cross-build.
    candidates = list((ndk.parents[1] / 'cmake').glob('*/bin/cmake' + ('.exe' if os.name == 'nt' else '')))
    if candidates:
        cmake = str(max(candidates, key=lambda p: tuple(int(v) for v in p.parents[1].name.split('.') if v.isdigit())))
if not cmake:
    cmake = shutil.which('cmake')
if not cmake:
    raise SystemExit('Install CMake through Android SDK Manager or set CMAKE to its executable.')
# Prefer rustup's target-aware toolchain over a Homebrew host-only installation.
if 'CARGO' not in os.environ and (Path.home() / '.cargo/bin/cargo').exists():
    cargo = str(Path.home() / '.cargo/bin/cargo')
TARGETS = [
    ('arm64-v8a', 'aarch64-linux-android', 'aarch64-linux-android'),
    ('armeabi-v7a', 'armv7-linux-androideabi', 'armv7a-linux-androideabi'),
]
rustup = shutil.which('rustup') or str(Path.home() / '.cargo/bin/rustup')
if Path(rustup).exists() or shutil.which(rustup):
    installed = subprocess.run([rustup, 'target', 'list', '--installed'], capture_output=True, text=True).stdout.split()
    missing = [t for _, t, _ in TARGETS if t not in installed]
    if missing:
        raise SystemExit('Rust is missing the Android targets. Run:\n  rustup target add ' + ' '.join(missing))
for abi, target, clang_target in TARGETS:
    env = os.environ.copy()
    suffix = '.cmd' if os.name == 'nt' else ''
    cc = str(toolchain / (clang_target + '23-clang' + suffix))
    env['CARGO_TARGET_' + target.upper().replace('-', '_') + '_LINKER'] = cc
    env['CC_' + target.replace('-', '_')] = cc
    env['AR_' + target.replace('-', '_')] = str(toolchain / ('llvm-ar.exe' if os.name == 'nt' else 'llvm-ar'))
    env['CXX_' + target.replace('-', '_')] = str(toolchain / (clang_target + '23-clang++' + suffix))
    env['CMAKE'] = cmake
    ninja = Path(cmake).with_name('ninja' + ('.exe' if os.name == 'nt' else ''))
    if ninja.exists():
        env.setdefault('CMAKE_GENERATOR', 'Ninja')
        env['PATH'] = str(ninja.parent) + os.pathsep + env.get('PATH', '')
    env['OPUS_NO_PKG'] = '1'
    env['KUMORI_ANDROID_NDK'] = str(ndk)
    env['KUMORI_ANDROID_ABI'] = abi
    env['CMAKE_TOOLCHAIN_FILE'] = str(root / 'android-toolchain.cmake')
    env['CARGO_TARGET_DIR'] = str(root / 'target')
    env['RUSTFLAGS'] = env.get('RUSTFLAGS', '') + ' -C link-arg=-Wl,-z,max-page-size=16384'
    subprocess.run([cargo, 'build', '--locked', '--release', '--manifest-path', str(root / 'Cargo.toml'), '--target', target], env=env, check=True)
    destination = output / abi
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / 'target' / target / 'release/libkumori_nvst.so', destination)
