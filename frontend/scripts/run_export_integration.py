"""Run the export integration test on an already booted Android emulator.

Usage: python scripts/run_export_integration.py [emulator-5554]
Drives only the system save picker for the synthetic 当当 export fixtures.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    root = Path(__file__).resolve().parents[1]
    device = sys.argv[1] if len(sys.argv) > 1 else 'emulator-5554'
    adb = shutil.which('adb')
    flutter = shutil.which('flutter')
    if not adb or not flutter:
        raise SystemExit('adb and flutter must be on PATH')

    def android(*args, check=True):
        return subprocess.run([adb, '-s', device, *args], capture_output=True,
                              check=check, timeout=20).stdout

    out = root / 'build' / 'export-integration'
    out.mkdir(parents=True, exist_ok=True)
    # This runner uses a dedicated test emulator. Remove only its previous
    # fixture exports so Android need not prompt about existing filenames.
    for role in ['owner', 'editor', 'viewer']:
        android('shell', 'rm', '-f', f'/sdcard/Download/当当{role}.zip')
    log = (out / 'test.log').open('w', encoding='utf-8')
    command = [
        flutter, 'drive', '--driver=test_driver/pet_export_driver.dart',
        '--target=integration_test/pet_export_test.dart',
        # Regenerate Android plugin registration when switching from release
        # back to a test build (integration_test is a dev-only plugin).
        '-d', device, '--no-dds',
    ]
    process = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 1200
    handled = set()
    try:
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(2)
            activity = android('shell', 'dumpsys', 'activity', 'activities').decode('utf-8', errors='replace')
            resumed = '\n'.join(line for line in activity.splitlines() if 'ResumedActivity' in line)
            if 'documentsui' not in resumed:
                continue
            android('shell', 'uiautomator', 'dump', '/sdcard/export-picker.xml', check=False)
            raw = android('shell', 'cat', '/sdcard/export-picker.xml', check=False)
            try:
                tree = ET.fromstring(raw)
            except ET.ParseError:
                continue
            texts = [node.get('text', '') for node in tree.iter('node')
                     if node.get('class') == 'android.widget.EditText']
            filename = next((t for t in texts if t.startswith('当当') and t.endswith('.zip')), None)
            if not filename or filename in handled:
                continue
            (out / f'{filename}.xml').write_bytes(raw)
            (out / f'{filename}.png').write_bytes(android('exec-out', 'screencap', '-p'))
            if filename == '当当取消.zip':
                android('shell', 'input', 'keyevent', '4')
            else:
                buttons = [n for n in tree.iter('node')
                           if n.get('enabled') == 'true' and (
                               n.get('resource-id', '').endswith(':id/button1')
                               or n.get('text', '').upper() in ('SAVE', '保存'))]
                if not buttons:
                    continue
                x1, y1, x2, y2 = map(int, re.findall(r'\d+', buttons[-1].get('bounds')))
                android('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
            handled.add(filename)
            print(f'Handled picker: {filename}', flush=True)
        if process.poll() is None:
            process.terminate()
            raise RuntimeError('Integration test timed out; inspect build/export-integration/test.log')
        if process.returncode:
            raise RuntimeError(f'Flutter integration failed ({process.returncode}); inspect test.log')
    finally:
        log.close()
        if process.poll() is None:
            process.terminate()

    assert handled == {'当当取消.zip', '当当owner.zip', '当当editor.zip', '当当viewer.zip'}, handled
    for role in ['owner', 'editor', 'viewer']:
        name = f'当当{role}'
        local = out / f'{name}.zip'
        android('pull', f'/sdcard/Download/{name}.zip', str(local))
        with zipfile.ZipFile(local) as archive:
            assert archive.testzip() is None
            assert archive.read('photos/1.jpg') == bytes([255, 216, 255, 1, 0, 127])
            assert archive.read('photos/2.png') == bytes([137, 80, 78, 71, 2, 0, 255])
            data = json.loads(archive.read(f'{name}.json'))
            assert data['pet']['name'] == name
            assert data['pet']['bath_cycle_days'] == 14
            assert all(len(data['records'][key]) == 1 for key in (
                'weights', 'dewormings', 'vaccinations', 'routines'))
        print(f'Verified saved ZIP: {name}.zip', flush=True)


if __name__ == '__main__':
    main()
