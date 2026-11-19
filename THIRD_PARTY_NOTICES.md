# Third-party notices

## SideScreen

The private `CGVirtualDisplay` declarations in `CVirtualDisplay/include/CGVirtualDisplayBridge.h`
and the virtual-display setup approach in `FileFoundryApp/SecondScreen/VirtualDisplay.swift`
are adapted from SideScreen (https://github.com/tranvuongquocdat/SideScreen).

MIT License

Copyright (c) 2025 Side Screen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## FFmpeg (bundled)

`FileFoundry.app/Contents/Helpers/ffmpeg` and `ffprobe` are separate programs built from unmodified upstream
sources by `scripts/build_ffmpeg.sh` (also copied to `Contents/Resources/FFmpeg/`), with `--enable-gpl`. They are
licensed under the GNU General Public License version 2 or later, not under File Foundry's MIT license.
File Foundry runs them as separate processes.

Included libraries: FFmpeg (LGPL 2.1+/GPL 2+), x264 (GPL 2+), x265 (GPL 2+), libvpx (BSD-3-Clause),
libwebp (BSD-3-Clause), LAME (LGPL 2+), Opus (BSD-3-Clause). Exact versions, URLs and SHA-256 checksums are in
`Contents/Resources/FFmpeg/SOURCES.txt`. The complete corresponding source tarballs are published on the
`ffmpeg-sources-9.0.2` release of https://github.com/junowoz/file-foundry and are available on request from the author.

