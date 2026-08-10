import argparse
import plistlib
import zipfile
from pathlib import Path


PERMISSIONS = {
    "NSBluetoothAlwaysUsageDescription": "Connect to the ESP32 tracker over Bluetooth.",
    "NSCameraUsageDescription": "Learn, track, and record your water rocket.",
    "NSMicrophoneUsageDescription": "Record audio together with the test video.",
    "NSPhotoLibraryAddUsageDescription": "Save recorded test videos to Photos.",
}


def patch_ipa(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    if destination.exists():
        raise FileExistsError(destination)

    plist_seen = False
    with zipfile.ZipFile(source, "r") as input_zip, zipfile.ZipFile(
        destination, "w", compression=zipfile.ZIP_DEFLATED
    ) as output_zip:
        for entry in input_zip.infolist():
            data = input_zip.read(entry.filename)
            if entry.filename.startswith("Payload/") and entry.filename.endswith(
                ".app/Info.plist"
            ):
                info = plistlib.loads(data)
                info.update(PERMISSIONS)
                data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
                plist_seen = True
            output_zip.writestr(entry, data)

    if not plist_seen:
        destination.unlink(missing_ok=True)
        raise RuntimeError("Could not find Payload/*.app/Info.plist")


def verify_ipa(path: Path) -> None:
    with zipfile.ZipFile(path, "r") as archive:
        plist_name = next(
            name
            for name in archive.namelist()
            if name.startswith("Payload/") and name.endswith(".app/Info.plist")
        )
        info = plistlib.loads(archive.read(plist_name))
        missing = [key for key in PERMISSIONS if not info.get(key)]
        if missing:
            raise RuntimeError(f"Missing permission keys: {', '.join(missing)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    patch_ipa(args.source, args.destination)
    verify_ipa(args.destination)
    print(args.destination)


if __name__ == "__main__":
    main()
