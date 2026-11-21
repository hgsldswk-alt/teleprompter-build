"""Render the manual App Store signing options without reading secrets."""
import os
from pathlib import Path
import plistlib
import sys

data = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
data["teamID"] = os.environ["TEAM_ID"]
data["provisioningProfiles"] = {os.environ.get("APP_ID", "com.hgsldswk.teleprompter"): os.environ.get("APP_PROFILE", "TiCi AppStore")}
sys.stdout.buffer.write(plistlib.dumps(data))
