# Device catalog

One file per device someone ran dumbtv on, in `devices/`. Each file records what a
script cannot read from the TV: where Developer Options is, where the IP address
is shown, which dialogs needed a person, and what surprised them. The next owner
of the same model, or their coding agent, starts from there.

The list of devices, with what worked on each, is in the
[README](../README.md#tested-on) and on [dumbtv.org/tv](https://dumbtv.org/tv),
which picks up a new file within a day of it being merged.

## Adding your TV

Run `./scripts/contribute.sh` at the end of a session. It reads the model and build
from the TV, asks for the rest, writes `devices/<platform>-<brand>-<model>.yaml`,
validates it and prints the commands for a pull request.
[CONTRIBUTING.md](../CONTRIBUTING.md) has the details.

## File format

| Key | Required | What it holds |
|---|---|---|
| `id` | yes | the file name without `.yaml`: `<platform>-<brand>-<model>`, with `-<build>` added when one model has two reports |
| `title` | yes | the name the product is sold under |
| `contributors` | | GitHub usernames of the people who tested it |
| `platform` | yes | `fireos`, `androidtv`, `tizen`, `webos`, `roku` or `other` |
| `status` | | `tested` (the full pass ran and `verify.sh` exited 0), `partial` or `untested` |
| `tested_on` | | the build, from `ro.build.display.id` |
| `models` | | other model numbers the report applies to |
| `adb` | | `port`, `transport` (`wifi`, `ethernet`, `usb`) and the first-connection prompt |
| `developer_mode` | yes | the exact menu path |
| `ip_location` | yes | where the TV shows its IP address |
| `prompts` | | dialogs that blocked automation, each with `name` and the `fix` that dismissed it |
| `data` | yes | the package and settings lists the device uses |
| `launcher` | | how HOME was taken over: `mechanism`, `reason`, `fallback`, `quirk` |
| `quirks`, `known_limits` | | anything the next person should know |
| `notes` | | a one-line summary |
| `verify` | yes | the host lists `verify.sh` checks |

`schema.json` is the machine-readable version. Check a file with:

```sh
python3 catalog/validate.py
```

It needs only Python 3; with PyYAML installed it parses every level, which is
what CI does.

## Licence

The catalog is CC BY-SA 4.0 ([LICENSE](LICENSE)); the code is MIT.
