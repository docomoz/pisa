#!/usr/bin/env python3
"""Write the installer layout without Apple Events or machine-specific paths."""
import pathlib
import sys
from ds_store import DSStore
from mac_alias import Alias

root = pathlib.Path(sys.argv[1])
# Resolve real volume creation times and file IDs before compression. Finder rejects
# background settings when the alias does not identify the actual HFS image.
alias = Alias.for_file(str(root / ".background/background.tiff"))
alias.volume.posix_path = b"/Volumes/Pisa"
alias.volume.disk_image_alias = None
with DSStore.open(str(root / ".DS_Store"), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 120}, {600, 362}}", "ShowToolbar": False,
        "ShowStatusBar": False, "ShowPathbar": False, "ShowSidebar": False,
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False, "ShowTabView": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": alias.to_bytes(),
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
        "labelOnBottom": True, "textSize": 13.0, "iconSize": 128.0,
    }
    store["."]["icvl"] = ("type", b"icnv")
    store["Pisa.app"]["Iloc"] = (160, 200)
    store["Applications"]["Iloc"] = (440, 200)
# Validate the final file before putting it in the compressed disk image.
with DSStore.open(str(root / ".DS_Store"), "r") as store:
    assert store["Pisa.app"]["Iloc"] == (160, 200)
    assert store["Applications"]["Iloc"] == (440, 200)
    assert store["."]["icvp"]["backgroundType"] == 2

assert b"/Users/" not in (root / ".DS_Store").read_bytes()
