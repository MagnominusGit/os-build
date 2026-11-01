# firmware/topology/

AudioReach topologies written here, for boards whose card has none in linux-firmware or the
qcom-firmwares repo. The `.m4` is the source; the built `-tplg.bin` ships from
`rootfs/overlay/usr/lib/firmware/qcom/<card driver_name>/`, the path the kernel requests
(`qcom/<driver_name>/<model>-tplg.bin`).

| Source | Built | Boards |
|---|---|---|
| `MangmiAirX.m4` | `qcom/sm8450/MangmiAirX-tplg.bin` (sha256 `c5279bf7…0e77`), `MangmiAirY-tplg.bin` a link to it | MANGMI Air X, Air Y (SM6115) |

Rebuild against [linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology)
(`b4c1510`, 2026-09-30, reproduces the binary byte for byte):

```
m4 -I <audioreach-topology> MangmiAirX.m4 > MangmiAirX.conf
alsatplg -c MangmiAirX.conf -o MangmiAirX-tplg.bin
```

alsatplg's "undefined widget/stream" warnings for the MI2S and VA stream names are expected: the
kernel's back-end DAIs provide them.
