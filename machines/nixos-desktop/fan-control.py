import argparse
import json
import math
import os
import signal
import socket
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HWMON = Path("/sys/class/hwmon")
FANS_HWMON = "nct6687"
DEADBAND_RPM = 30
KP = 0.3
INTEGRAL_S = 20
START_GRACE_S = 10
KICK_S = 3
SENSOR_WAIT_S = 20
SUMMARY_S = 60
CPU_RANGE = (0, 115)
GPU_RANGE = (0, 125)
CALIBRATION_STEPS = [255, 200, 160, 120, 100, 90, 80, 72]
CALIBRATION_MIN_S = 8
CALIBRATION_MAX_S = 60
CALIBRATION_SETTLED_RPM = 10
CALIBRATION_ABORT_C = 70
FLOOR_MARGIN_PWM = 6


class FanError(Exception):
    pass


def log(message):
    print(message, file=sys.stderr, flush=True)


def find_hwmon(name):
    for path in sorted(HWMON.glob("hwmon*")):
        try:
            if (path / "name").read_text().strip() == name:
                return path
        except OSError:
            continue
    raise FanError(f"no hwmon named {name} under {HWMON}")


def find_temp(name, label):
    found = []
    for hwmon in HWMON.glob("hwmon*"):
        try:
            if (hwmon / "name").read_text().strip() != name:
                continue
            for path in hwmon.glob("temp*_label"):
                if path.read_text().strip() == label:
                    found.append(
                        path.with_name(path.name.replace("_label", "_input")))
        except OSError:
            continue
    if len(found) != 1:
        raise FanError(
            f"expected one {name} temperature labelled {label}, found "
            f"{[str(path) for path in found]}")
    return found[0]


def wait_for_temp(name, label):
    deadline = time.monotonic() + SENSOR_WAIT_S
    while True:
        try:
            return find_temp(name, label)
        except FanError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)


def read_int(path):
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError) as error:
        raise FanError(f"cannot read {path}: {error}") from error


def write_int(path, value):
    try:
        path.write_text(f"{int(value)}\n")
    except OSError as error:
        raise FanError(f"cannot write {value} to {path}: {error}") from error


def read_celsius(path, valid):
    celsius = read_int(path) / 1000
    if not valid[0] <= celsius <= valid[1]:
        raise FanError(f"{path} reads {celsius} C, outside {valid}")
    return celsius


def interp(points, x):
    if x <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return points[-1][1]


def clamp(value, low, high):
    return max(low, min(high, value))


@dataclass
class Table:
    floor_pwm: int
    points: list

    @classmethod
    def parse(cls, entry):
        points = [(int(pwm), int(rpm)) for pwm, rpm in entry["table"]]
        pwms = [pwm for pwm, _ in points]
        rpms = [rpm for _, rpm in points]
        if len(points) < 2 or pwms != sorted(set(pwms)):
            raise FanError(f"channel {entry['channel']}: bad PWM column")
        if rpms != sorted(rpms):
            raise FanError(f"channel {entry['channel']}: RPM not rising")
        return cls(int(entry["floor_pwm"]), points)

    @property
    def max_rpm(self):
        return self.points[-1][1]

    @property
    def floor_rpm(self):
        return interp(self.points, self.floor_pwm)

    def segment(self, rpm):
        for low, high in zip(self.points, self.points[1:]):
            if rpm <= high[1] and high[1] > low[1]:
                return low, high
        return self.points[-2], self.points[-1]

    def pwm_for(self, rpm):
        (pwm0, rpm0), (pwm1, rpm1) = self.segment(rpm)
        if rpm1 == rpm0:
            return pwm1
        return pwm0 + (pwm1 - pwm0) * (rpm - rpm0) / (rpm1 - rpm0)

    def slope(self, rpm):
        (pwm0, rpm0), (pwm1, rpm1) = self.segment(rpm)
        return max(1.0, (rpm1 - rpm0) / (pwm1 - pwm0))


@dataclass
class Ema:
    rise_s: float
    fall_s: float
    value: float = None

    def update(self, sample, dt):
        if self.value is None:
            self.value = sample
            return sample
        tau = self.rise_s if sample > self.value else self.fall_s
        self.value += (sample - self.value) * (1 - math.exp(-dt / tau))
        return self.value


@dataclass
class Channel:
    name: str
    number: int
    table: Table
    rise_pwm: int
    integral: float = 0.0
    pwm: int = 255
    zero_reads: int = 0

    def next_pwm(self, target, rpm, dt):
        error = target - rpm
        if abs(error) <= DEADBAND_RPM:
            error = 0
        slope = self.table.slope(target)
        base = self.table.pwm_for(target) + KP * error / slope
        integral = self.integral + error * dt / (INTEGRAL_S * slope)
        wanted = base + integral
        limited = clamp(wanted, self.pwm - 2, self.pwm + self.rise_pwm)
        limited = clamp(limited, self.table.floor_pwm, 255)
        if abs(limited - wanted) < 0.5:
            self.integral = integral
        self.pwm = round(limited)
        return self.pwm


@dataclass
class Policy:
    radiator_curve: list
    intake_curve: list
    rear_rpm: float
    radiator_weight: float
    rear_weight: float

    def targets(self, cpu, gpu, radiator, rear, intakes, rpm):
        rear_target = clamp(
            self.rear_rpm, rear.table.floor_rpm, rear.table.max_rpm)
        rear_flow = max(rear_target, rpm[rear.name])
        intake_max = min(fan.table.max_rpm for fan in intakes)
        intake_min = max(fan.table.floor_rpm for fan in intakes)
        cap = (intake_max - self.rear_weight * rear_flow)
        cap /= self.radiator_weight
        demand = interp(self.radiator_curve, cpu)
        radiator_target = clamp(
            min(demand, cap),
            radiator.table.floor_rpm,
            radiator.table.max_rpm)
        radiator_flow = max(radiator_target, rpm[radiator.name])
        pressure = (self.radiator_weight * radiator_flow
                    + self.rear_weight * rear_flow)
        intake_target = clamp(
            max(interp(self.intake_curve, gpu), pressure),
            intake_min, intake_max)
        targets = {radiator.name: radiator_target, rear.name: rear_target}
        for fan in intakes:
            targets[fan.name] = intake_target
        return targets, demand, cap


@dataclass
class Emergency:
    enter_filtered_c: float
    enter_raw_c: float
    leave_filtered_c: float
    leave_s: float
    active: bool = False
    cool_since: float = None

    def update(self, filtered, raw, now):
        if filtered >= self.enter_filtered_c or raw >= self.enter_raw_c:
            self.active = True
            self.cool_since = None
        elif self.active and filtered < self.leave_filtered_c:
            if self.cool_since is None:
                self.cool_since = now
            elif now - self.cool_since >= self.leave_s:
                self.active = False
        elif self.active:
            self.cool_since = None
        return self.active


@dataclass
class Config:
    period_s: float
    cpu_path: Path
    gpu_path: Path
    cpu_ema: Ema
    gpu_ema: Ema
    radiator: Channel
    rear: Channel
    intakes: list
    policy: Policy
    emergency: Emergency
    channels: list = field(init=False)

    def __post_init__(self):
        self.channels = [self.radiator, self.rear, *self.intakes]


def channel(name, entry, rise_pwm):
    return Channel(name, int(entry["channel"]), Table.parse(entry), rise_pwm)


def load_config(path):
    raw = json.loads(Path(path).read_text())
    cpu, gpu = raw["cpu"], raw["gpu"]
    intakes = [channel(f"intake{entry['channel']}", entry, 10)
               for entry in raw["intakes"]]
    emergency = raw["emergency"]
    return Config(
        period_s=float(raw["period_s"]),
        cpu_path=wait_for_temp(cpu["hwmon"], cpu["label"]),
        gpu_path=wait_for_temp(gpu["hwmon"], gpu["label"]),
        cpu_ema=Ema(cpu["rise_s"], cpu["fall_s"]),
        gpu_ema=Ema(gpu["rise_s"], gpu["fall_s"]),
        radiator=channel("radiator", raw["radiator"], 6),
        rear=channel("rear", raw["rear"], 6),
        intakes=intakes,
        policy=Policy(
            radiator_curve=raw["radiator_curve"],
            intake_curve=raw["intake_curve"],
            rear_rpm=float(raw["rear_rpm"]),
            radiator_weight=float(raw["pressure"]["radiator"]),
            rear_weight=float(raw["pressure"]["rear"])),
        emergency=Emergency(
            float(emergency["enter_filtered_c"]),
            float(emergency["enter_raw_c"]),
            float(emergency["leave_filtered_c"]),
            float(emergency["leave_s"])))


def notify(message):
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
        sock.sendto(message.encode(), address)


def take_manual(hwmon, number, announce):
    enable = hwmon / f"pwm{number}_enable"
    if read_int(enable) != 1:
        write_int(enable, 1)
        if announce:
            log(f"channel {number} left manual mode; set it back")


def kick(hwmon, stalled, rpm):
    for fan in stalled:
        log(f"channel {fan.number} reads 0 rpm; kicking at PWM 255")
        write_int(hwmon / f"pwm{fan.number}", 255)
    notify("WATCHDOG=1")
    time.sleep(KICK_S)
    for fan in stalled:
        rpm[fan.name] = read_int(hwmon / f"fan{fan.number}_input")
        if rpm[fan.name] == 0:
            raise FanError(f"stall on channel {fan.number}")
        fan.pwm = 255
        fan.zero_reads = 0


def write_state(state):
    directory = Path(os.environ.get("RUNTIME_DIRECTORY", "/run/case-fans"))
    temporary = directory / "state.json.tmp"
    temporary.write_text(json.dumps(state))
    os.replace(temporary, directory / "state.json")


def run(config_path):
    config = load_config(config_path)
    hwmon = find_hwmon(FANS_HWMON)
    for fan in config.channels:
        fan.pwm = read_int(hwmon / f"pwm{fan.number}")
    started = last = time.monotonic()
    last_summary = 0.0
    first = True
    mode = "normal"
    while True:
        now = time.monotonic()
        dt = max(now - last, 0.1)
        last = now
        cpu_raw = read_celsius(config.cpu_path, CPU_RANGE)
        gpu_raw = read_celsius(config.gpu_path, GPU_RANGE)
        cpu = config.cpu_ema.update(cpu_raw, dt)
        gpu = config.gpu_ema.update(gpu_raw, dt)
        rpm = {fan.name: read_int(hwmon / f"fan{fan.number}_input")
               for fan in config.channels}
        targets, demand, cap = config.policy.targets(
            cpu, gpu, config.radiator, config.rear, config.intakes, rpm)
        emergency = config.emergency.update(cpu, cpu_raw, now)
        new_mode = "emergency" if emergency else "normal"
        if new_mode != mode:
            log(f"mode {mode} -> {new_mode} at Tctl {cpu_raw:.1f} C "
                f"(filtered {cpu:.1f} C)")
            mode = new_mode
        for fan in config.channels:
            take_manual(hwmon, fan.number, announce=not first)
            stopped = now - started >= START_GRACE_S and rpm[fan.name] == 0
            fan.zero_reads = fan.zero_reads + 1 if stopped else 0
        stalled = [fan for fan in config.channels if fan.zero_reads >= 2]
        if stalled:
            kick(hwmon, stalled, rpm)
        channels = {}
        for fan in config.channels:
            if emergency:
                fan.pwm = 255
            else:
                fan.next_pwm(targets[fan.name], rpm[fan.name], dt)
            write_int(hwmon / f"pwm{fan.number}", fan.pwm)
            channels[fan.name] = {
                "channel": fan.number,
                "target": round(targets[fan.name]),
                "rpm": rpm[fan.name],
                "pwm": fan.pwm,
            }
        write_state({
            "time": time.time(),
            "mode": mode,
            "cpu_raw": cpu_raw,
            "cpu": round(cpu, 2),
            "gpu_raw": gpu_raw,
            "gpu": round(gpu, 2),
            "radiator_demand": round(demand),
            "cap": round(cap),
            "channels": channels,
        })
        if first:
            log(f"controlling channels "
                f"{[fan.number for fan in config.channels]}")
            notify("READY=1")
            first = False
        notify("WATCHDOG=1")
        if now - last_summary >= SUMMARY_S:
            last_summary = now
            log(f"{mode} Tctl {cpu:.1f} C GPU {gpu:.1f} C " + " ".join(
                f"{name} {c['rpm']}/{c['target']}rpm pwm {c['pwm']}"
                for name, c in channels.items()))
        time.sleep(max(0.0, config.period_s - (time.monotonic() - now)))


def restore(channels):
    hwmon = find_hwmon(FANS_HWMON)
    failed = []
    for number in channels:
        enable = hwmon / f"pwm{number}_enable"
        try:
            write_int(enable, 2)
            if read_int(enable) != 2:
                failed.append(number)
        except FanError as error:
            log(str(error))
            failed.append(number)
    if failed:
        raise FanError(f"channels {failed} did not return to auto")
    log(f"channels {channels} returned to BIOS control")


def calibration_sample(hwmon, number, cpu_path):
    reads = []
    for second in range(1, CALIBRATION_MAX_S + 1):
        time.sleep(1)
        celsius = read_celsius(cpu_path, CPU_RANGE)
        if celsius >= CALIBRATION_ABORT_C:
            raise FanError(f"Tctl reached {celsius} C during calibration")
        reads.append(read_int(hwmon / f"fan{number}_input"))
        if reads[-1] == 0:
            return 0
        last = reads[-4:]
        settled = max(last) - min(last) <= CALIBRATION_SETTLED_RPM
        if second >= CALIBRATION_MIN_S and len(last) == 4 and settled:
            break
    return round(statistics.median(reads[-3:]))


def stop_on_signal(signum, _frame):
    raise SystemExit(f"case-fans-control: stopped by signal {signum}")


def calibrate(number):
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, stop_on_signal)
    hwmon = find_hwmon(FANS_HWMON)
    cpu_path = find_temp("k10temp", "Tctl")
    pwm_path = hwmon / f"pwm{number}"
    table = []
    try:
        write_int(hwmon / f"pwm{number}_enable", 1)
        write_int(pwm_path, 255)
        steps = CALIBRATION_STEPS + list(range(68, 0, -4))
        for pwm in steps:
            write_int(pwm_path, pwm)
            rpm = calibration_sample(hwmon, number, cpu_path)
            if rpm == 0:
                write_int(pwm_path, 255)
                break
            table.append([pwm, rpm])
            log(f"channel {number}: PWM {pwm} -> {rpm} rpm")
    finally:
        restore([number])
    table.sort()
    if not table:
        raise FanError(f"channel {number} never turned")
    for low, high in zip(table, table[1:]):
        if high[1] < low[1]:
            raise FanError(
                f"channel {number}: PWM {high[0]} read {high[1]} rpm, "
                f"below {low[1]} rpm at PWM {low[0]}; calibrate again")
    print(json.dumps({
        "channel": number,
        "floor_pwm": table[0][0] + FLOOR_MARGIN_PWM,
        "table": table,
    }))


def channel_list(text):
    return [int(part) for part in text.split(",")]


def main():
    parser = argparse.ArgumentParser(prog="case-fans-control")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--config", type=Path)
    action.add_argument("--restore", type=channel_list)
    action.add_argument("--calibrate", type=int)
    args = parser.parse_args()
    try:
        if args.restore is not None:
            restore(args.restore)
        elif args.calibrate is not None:
            calibrate(args.calibrate)
        else:
            run(args.config)
    except FanError as error:
        log(f"case-fans-control: {error}")
        sys.exit(1)


if __name__ == "__main__":
    main()
