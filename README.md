# Wappclaw distribution

Build artifacts only. No source code lives here, and nothing here is edited by hand —
every file is published by CI from the private product repository.

## Install

    curl -fsSL https://raw.githubusercontent.com/qcnguyen/wappclaw-dist/main/install.sh | bash
    wapp start

To install the newest development build instead of the newest stable one:

    curl -fsSL https://raw.githubusercontent.com/qcnguyen/wappclaw-dist/main/install.sh | WAPP_CHANNEL=dev bash

The variable goes on `bash`, not on `curl` — before `curl` it lands in curl's
environment and the installer never sees it.

| File | What it is |
| --- | --- |
| `install.sh` | The installer. |
| `latest` | Newest stable version. |
| `latest-dev` | Newest development version. |

Tarballs are attached to Releases rather than committed, so this repository stays small.

Running Wappclaw requires a licence key. Downloading is unrestricted; the licence is what
permits an operator to run it.
