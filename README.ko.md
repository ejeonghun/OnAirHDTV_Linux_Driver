[English](README.md) | **한국어**

# OnAir GT USB HDTV Linux DVB Driver

[![Build](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/actions/workflows/build.yml/badge.svg)](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/actions/workflows/build.yml)

**OnAir GT USB HDTV** ATSC 튜너용 out-of-tree 리눅스 커널 드라이버입니다. ATSC 8VSB(지상파, 국내/미국 케이블)를 수신하며, 튜너를 표준 DVB 장치 `/dev/dvb/adapterN`으로 노출합니다.

## 지원 하드웨어

| 장치 | USB ID | USB 브리지 | 복조기 | 튜너 | 프런트엔드 |
|------|--------|-----------|--------|------|-----------|
| OnAir GT USB HDTV | `11ba:1101` | Cypress CY7C68013A (FX2) | LG LGDT3303 | LG TDVS-H062F (tuner-simple `TUNER_LG_TDVS_H06XF`) | 1 (ATSC 8VSB, QAM은 미검증) |

보드에는 Conexant CX25843 아날로그 디코더도 있지만 아날로그 TV는 지원하지 않습니다. 장치는 USB 2.0 고속(high speed)으로 연결해야 합니다. 그렇지 않으면 드라이버가 `device is not running at USB high speed`를 기록하고 시작하지 않습니다.

## 모듈

| 모듈 | 설명 |
|------|------|
| `dvb-usb-onairgt.ko` | FX2 USB 브리지 드라이버(dvb-usb-v2). 커널 내장 `dvb_usb_v2`, `lgdt330x`, `tuner-simple` 모듈을 사용합니다. |

빌드에는 대상 커널 `drivers/media`의 `dvb_usb.h`, `lgdt330x.h`, `tuner-simple.h`가 필요합니다. 배포판 헤더 패키지에는 이 파일들이 없고, 구조체가 실행 중인 `dvb_usb_v2`와 정확히 일치해야 합니다(레이아웃 구간 세 가지: 4.4-4.16, 4.17-5.4, 5.5 이상). `kheaders.sh`는 커널의 업스트림 버전에 맞는 파일을 kernel.org stable 트리에서 내려받아 내용을 검사하고, SHA-256을 기록한 뒤 캐시합니다. 따라서 새 커널 버전마다 첫 빌드에는 인터넷 연결이 필요합니다. 오프라인이면 5.5 이상 커널에 한해 동봉된 Linux 7.0 사본(`fallback-kheaders/`)을 경고와 함께 사용하고, 그보다 오래된 커널에서는 빌드를 중단합니다. `KDIR`이 전체 커널 소스 트리이면 그 트리의 헤더를 사용합니다. 자세한 내용: [docs/driver-internals.md](docs/driver-internals.md#kernel-private-headers)

## 설치 (패키지)

DKMS 패키지는 [GitHub Releases](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/releases)에 첨부되어 있습니다. 패키지는 소스를 `/usr/src/onairgt-<버전>/`에 설치하고, 헤더가 설치된 모든 커널용으로 모듈을 빌드합니다. 커널이 업데이트되면 DKMS가 다시 빌드합니다.

먼저 실행 중인 커널의 헤더를 설치합니다(Debian/Ubuntu는 `linux-headers-$(uname -r)`, Fedora는 `kernel-devel-$(uname -r)`). Ubuntu에서는 커널 내장 DVB 모듈이 `linux-modules-extra-$(uname -r)`에 들어 있습니다.

### Debian / Ubuntu

```sh
sudo apt install ./onairgt-dkms_*.deb       # dkms도 함께 설치
# dkms가 이미 설치되어 있으면:
sudo dpkg -i onairgt-dkms_*.deb
```

제거:

```sh
sudo apt remove onairgt-dkms        # purge하면 /var/cache/onairgt의 헤더 캐시도 삭제
```

### Fedora

```sh
sudo dnf install ./onairgt-dkms-*.noarch.rpm
```

제거:

```sh
sudo dnf remove onairgt-dkms
```

RHEL, Rocky, AlmaLinux의 기본 커널은 DVB 서브시스템 없이 빌드되어 있어 드라이버를 로드할 수 없습니다. [docs/installation-notes.md](docs/installation-notes.md#supported-distributions)를 참고하십시오.

## 설치 (DKMS, 소스에서)

```sh
git clone https://github.com/ejeonghun/OnAirHDTV_Linux_Driver.git
cd OnAirHDTV_Linux_Driver
sudo dkms add .
sudo dkms build onairgt/0.3
sudo dkms install onairgt/0.3
```

`dkms add .`는 체크아웃 전체를 `/usr/src/onairgt-0.3`으로 복사합니다. `sudo make dkms-install`은 같은 세 단계를 수행하되 드라이버 파일만 복사합니다.

제거:

```sh
sudo dkms remove onairgt/0.3 --all
sudo rm -rf /usr/src/onairgt-0.3
```

DKMS 빌드는 내려받은 헤더를 `/var/cache/onairgt/kheaders`에 보관합니다.

## 빌드 (수동)

`make`, `gcc`, `curl` 또는 `wget`, 대상 커널의 헤더가 필요합니다.

```sh
make
sudo make install       # /lib/modules/$(uname -r)/updates, depmod 실행
```

제거:

```sh
sudo make uninstall
```

특정 커널용으로 빌드:

```sh
make KVER=6.8.0-147-generic                    # KDIR 기본값은 /lib/modules/$KVER/build
make KVER=5.10.55 KDIR=/path/to/linux-5.10.55  # 전체 소스 트리: 트리 자체의 헤더 사용
```

내려받은 헤더는 `./kheaders`에 캐시되며, `make distclean`으로 삭제합니다.

## 펌웨어

FX2 펌웨어를 보드의 EEPROM에서 부팅하는 장치에는 필요하지 않습니다. 테스트한 장치도 그렇습니다.

EEPROM이 비어 있는 장치는 "cold" 상태로 인식되고 `/lib/firmware/dvb-usb-onairgt-01.fw`를 요청합니다. 직접 가지고 있는 Windows 드라이버에서 추출하십시오.

```sh
sudo tools/extract-firmware.sh /path/to/OnAirGt64.sys    # 또는 OnAirGt.sys, 7168바이트 원본 이미지
```

스크립트는 설치 전에 이미지의 SHA-256을 확인합니다. cold 부팅 경로는 실제 하드웨어에서 테스트하지 않았습니다. 제조사 펌웨어는 이 드라이버와 함께 배포하지 않습니다.

## 모듈 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `xfer` | `0` | TS 전송 방식: `0` isochronous(alt setting 6, Windows 드라이버와 동일), `1` bulk(alt setting 0). 둘 다 오류 없이 검증되었습니다. isochronous 지원이 불안정한 USB 컨트롤러나 VM에서는 `1`을 사용해 보십시오. |
| `win_ts` | `1` | Windows식 LGDT3303 TS 설정(레지스터 0x87, 0x47). `1`로 유지하십시오. `0`이면 테스트한 보드에서 TS가 깨집니다. |
| `clock_flip` | `0` | lgdt330x `clock_polarity_flip`(0, 1, 2). 디버깅 전용입니다. |
| `adapter_nr` | 자동 | DVB 어댑터 번호 |

예시, `/etc/modprobe.d/dvb-usb-onairgt.conf`:

```
options dvb-usb-onairgt xfer=1
```

## 사용법

dvbv5 형식의 스캔 테이블은 `tools/scan-tables/`에 있습니다.

| 파일 | 채널 |
|------|------|
| `kr-cable-8vsb-std` | 국내/미국 케이블 8VSB, STD 플랜(하드웨어 테스트 완료) |
| `kr-cable-8vsb-hrc`, `kr-cable-8vsb-irc` | 케이블 8VSB, HRC / IRC 플랜 |
| `kr-atsc-terrestrial` | 국내 지상파 ATSC, UHF 14-51 |
| `us-atsc-terrestrial` | 미국 지상파 ATSC, VHF 2-13 및 UHF 14-36 |

```sh
dvbv5-scan -T 4 -o channels.conf tools/scan-tables/kr-cable-8vsb-std
dvbv5-zap -c channels.conf -r -o ktv.ts -t 10 KTV
```

테스트한 국내 케이블 신호에서는 `dvbv5-scan`에 `-T 4`가 필요합니다. 기본 테이블 타임아웃으로는 "not found on PMT"가 표시됩니다. 도구는 `dvb-tools`(Debian/Ubuntu) 또는 `v4l-utils`(Fedora) 패키지에 있습니다.

### TVHeadend

`tools/install.sh`는 일괄 설치 스크립트입니다. DKMS로 드라이버를 빌드하고, TVHeadend를 설치(배포판 패키지, 공식 apt 저장소, Docker, 소스 빌드)한 뒤 설정(관리자 계정, ATSC 네트워크, 프리셋의 mux, 스캔, 채널 매핑)까지 할 수 있습니다. `sudo tools/install.sh --help`를 실행하십시오. `tools/uninstall.sh`로 되돌릴 수 있습니다. 설치 방식, 프리셋, 테스트 결과: [docs/installation-notes.md](docs/installation-notes.md)

## 테스트 현황

| 플랫폼 | 커널 | 상태 |
|--------|------|------|
| Ubuntu 26.04 (VMware VM, USB 패스스루) | 7.0.0-38-generic | 하드웨어 테스트: 락, 스캔, 60초 TS 캡처 sync/TEI/CC 오류 0, TVHeadend(Docker 경로 전 과정) |
| Ubuntu 18.04 (GA, HWE), 20.04, 22.04, 24.04 | 4.15, 5.4, 5.4, 5.15, 6.8 | 컴파일 테스트 |
| Debian 11, 12, 13 | 5.10, 6.1, 6.12 | 컴파일 테스트 |
| Fedora 44 | 7.2 | 컴파일 테스트 |
| kernel.org 바닐라 | 4.4.302, 5.10.55 | 컴파일 테스트(Synology DSM 커널 버전) |
| DKMS 패키지 | Ubuntu 24.04 (6.8), Fedora 44 (7.2) | 컨테이너에서 설치 테스트: DKMS가 모듈을 빌드하고 설치 |
| Synology / Xpenology DSM 7.2 | 4.4.302+, 5.10.55+ | 실험적, 실제 DSM 하드웨어에서 로드해 보지 않음. [synology/README.md](synology/README.md) 참고 |

컴파일 매트릭스: `sh ci/matrix.sh [target ...]`(docker). [.github/workflows/build.yml](.github/workflows/build.yml)에서도 실행됩니다. 하드웨어 테스트 결과: [docs/test-report.md](docs/test-report.md)

## 문제 해결

- `sudo tools/onairgt-doctor.sh`로 진단 보고서를 만들어(`--freq 195`를 붙이면 한 주파수의 락을 확인) 이슈에 첨부하십시오. 비밀번호는 출력하지 않습니다.
- `/dev/dvb/adapterN`이 없음: `lsusb -d 11ba:1101`과 `sudo dmesg | grep -iE 'onair|dvb|lgdt|11ba'`를 확인하십시오. `dvb-usb-onairgt-01.fw` 요청이 보이면 cold 장치입니다([펌웨어](#펌웨어) 참고).
- `device is not running at USB high speed`: USB 1.1 허브가 아닌 USB 2.0 이상 포트에 연결하십시오.
- Secure Boot: 커널은 등록된 키로 서명된 모듈만 로드합니다. `mokutil --sb-state`로 확인하고, `sudo mokutil --import /var/lib/dkms/mok.pub`(Ubuntu: `/var/lib/shim-signed/mok/MOK.der`)로 DKMS 키를 등록한 뒤 재부팅해 **Enroll MOK**를 선택하십시오.
- DKMS 빌드 실패: `/var/lib/dkms/onairgt/0.3/build/make.log`를 확인하십시오. 5.5 미만 커널에서 헤더 다운로드에 실패하면 빌드가 중단됩니다. 네트워크에 연결한 뒤 `sudo dkms install onairgt/0.3 -k $(uname -r)`로 다시 빌드하십시오.
- VMware: **VM > Removable Devices > USB HDTV-GT > Connect**로 튜너를 연결합니다. 자동으로 연결하려면 VM을 끈 상태에서 `.vmx`에 `usb.autoConnect.device0 = "vid:0x11ba pid:0x1101"`을 추가하십시오. VM에서 isochronous 스트리밍이 불안정하면 `xfer=1`을 사용하십시오.
- TVHeadend에 채널은 있지만 재생되지 않음(서비스 없음, `{name-not-set}`): `sudo tools/install.sh --yes --tvh existing --preset kr-cable-8vsb`(사용하는 프리셋으로)로 기존 설치의 매핑을 다시 실행하십시오.

## 문서

| 문서 | 내용 |
|------|------|
| [docs/hardware.md](docs/hardware.md) | 부품, EEPROM 부팅, USB 인터페이스, LGDT3303 TS 설정, 튜너, 처리량 |
| [docs/protocol.md](docs/protocol.md) | FX2 펌웨어와 명령 세트, TS 스트리밍, I2C 맵, ATSC 튜닝, 초기화 순서 |
| [docs/usb-descriptors.txt](docs/usb-descriptors.txt) | USB 디스크립터 덤프 |
| [docs/driver-internals.md](docs/driver-internals.md) | 드라이버 구조, 커널 호환성, 비공개 헤더, 컴파일 매트릭스 |
| [docs/test-report.md](docs/test-report.md) | 하드웨어 테스트 결과 |
| [docs/installation-notes.md](docs/installation-notes.md) | `tools/` 설치 스크립트, TVHeadend 설정, 프리셋, 배포판별 참고 사항 |
| [synology/README.md](synology/README.md) | 실험적 Synology / Xpenology DSM 7.2 번들 |

## 라이선스

GPL-2.0-or-later. [LICENSE](LICENSE)를 참고하십시오.

이 프로젝트는 OnAirSolution과 관련이 없으며 승인받지 않았습니다. USB 프로토콜은 상호 운용을 위해 제조사 Windows 드라이버를 리버스 엔지니어링하여 파악했습니다. 제조사 펌웨어와 드라이버 파일은 배포하지 않습니다.
