"""xcresult attachments are authoritative; simulator test runner cannot always write host SHOTS_DIR."""
import pathlib
import shutil
import subprocess
import sys

result, output = sys.argv[1:3]
folder = pathlib.Path(output)
folder.mkdir(parents=True, exist_ok=True)
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                "--output-path", str(folder)], check=True)
pngs = list(folder.glob("**/*.png"))
if not pngs:
    sys.exit("界面测试没有导出 PNG 截图")
for index, path in enumerate(sorted(pngs), 1):
    if path.parent != folder:
        shutil.copy2(path, folder / f"{index:03d}-{path.name}")
print(f"已导出 {len(pngs)} 张界面测试截图到 {folder}")
