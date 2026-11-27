#!/usr/bin/env python3
"""Repair first-feed failure rollback in DSM 5.10 DVB USB source.

Limit changes to unfiltered adapters (OnAir GT). Refuse an unexpected
source layout. No exported symbols, structures or config options change.
"""
import pathlib
import sys


def patch(source):
    begin = source.index("static int dvb_usb_start_feed(")
    end = source.index("\n}", begin) + 2
    body = source[begin:end]

    def replace(old, new):
        nonlocal body
        if body.count(old) != 1:
            raise ValueError("unexpected DVB USB source: " + old)
        body = body.replace(old, new, 1)

    replace(
        "\t\tif (ret)\n\t\t\tdev_err(&d->udev->dev,\n\t\t\t\t\t\"%s: get_stream_config() failed=%d\\n\",\n\t\t\t\t\tKBUILD_MODNAME, ret);",
        "\t\tif (ret) {\n\t\t\tif (!adap->pid_filtering)\n\t\t\t\tgoto abort_first_feed;\n\t\t\tdev_err(&d->udev->dev,\n\t\t\t\t\t\"%s: get_stream_config() failed=%d\\n\",\n\t\t\t\t\tKBUILD_MODNAME, ret);\n\t\t}",
    )
    replace(
        "\tusb_urb_submitv2(&adap->stream, &stream_props);",
        "\tif (!adap->pid_filtering) {\n"
        "\t\tret = usb_urb_submitv2(&adap->stream, &stream_props);\n"
        "\t\tif (ret < 0)\n\t\t\tgoto abort_first_feed;\n"
        "\t} else {\n"
        "\t\tusb_urb_submitv2(&adap->stream, &stream_props);\n"
        "\t}",
    )
    replace(
        "\t\tret = d->props->streaming_ctrl(adap->fe[adap->active_fe], 1);",
        "\t\tret = d->props->streaming_ctrl(adap->fe[adap->active_fe], 1);\n"
        "\t\tif (ret < 0 && !adap->pid_filtering)\n\t\t\tgoto abort_first_feed;",
    )
    replace(
        "\treturn ret;\n}",
        "\treturn ret;\n\n"
        "abort_first_feed:\n"
        "\t/* The demux will not stop a feed whose start failed. */\n"
        "\tusb_urb_killv2(&adap->stream);\n"
        "\tadap->feed_count--;\n"
        "\tclear_bit(ADAP_STREAMING, &adap->state_bits);\n"
        "\tsmp_mb__after_atomic();\n"
        "\twake_up_bit(&adap->state_bits, ADAP_STREAMING);\n"
        "\treturn ret;\n}",
    )
    return source[:begin] + body + source[end:]


if __name__ == "__main__":
    path = pathlib.Path(sys.argv[1])
    updated = patch(path.read_text())
    path.write_text(updated)
    print("Applied DSM 5.10 unfiltered DVB first-feed rollback")
