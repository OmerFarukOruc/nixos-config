import argparse
import base64
import os
from contextlib import ExitStack
from pathlib import Path

from generate_image import (
    IMAGE_TOOL_MODELS,
    VALID_BACKGROUND,
    VALID_QUALITY,
    die,
    load_prompt,
    validate_size,
)
from openai import APIError, APIStatusError, OpenAI
from PIL import Image


def main():
    parser = argparse.ArgumentParser(
        description="Generate or edit one PNG through the OpenAI Images API."
    )
    parser.add_argument("--image-model", choices=IMAGE_TOOL_MODELS, required=True)
    parser.add_argument("--quality", choices=sorted(VALID_QUALITY), required=True)
    parser.add_argument("--size", type=validate_size, required=True)
    parser.add_argument("--complexity", choices=("low", "medium", "high"))
    parser.add_argument("--background", choices=sorted(VALID_BACKGROUND))
    parser.add_argument("--reference", type=Path, action="append", default=[])
    parser.add_argument("--prompt")
    parser.add_argument("--prompt-file")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    params = {
        "model": args.image_model,
        "quality": args.quality,
        "size": args.size,
        "prompt": load_prompt(args),
        "output_format": "png",
        "n": 1,
    }
    if not params["prompt"].strip():
        parser.error("Supply a nonempty prompt.")
    for path in args.reference:
        if not path.is_file():
            parser.error(f"Reference file missing: {path}")
    if args.complexity:
        params["complexity"] = args.complexity
    if args.background:
        params["background"] = args.background
    if (
        args.output.suffix.lower() != ".png"
        or args.output.exists()
        or not args.output.parent.is_dir()
    ):
        parser.error("--output needs an unused .png path inside an existing directory")
    if not os.getenv("OPENAI_API_KEY"):
        parser.error("Supply OPENAI_API_KEY from the selected API project.")
    with ExitStack() as stack:
        client = stack.enter_context(
            OpenAI(base_url="https://api.openai.com/v1", max_retries=0)
        )
        try:
            if args.reference:
                inputs = [
                    stack.enter_context(path.open("rb")) for path in args.reference
                ]
                result = client.images.edit(image=inputs, **params)
            else:
                result = client.images.generate(**params)
        except APIStatusError as error:
            raise SystemExit(
                f"Images API returned HTTP {error.status_code} ({error.code})."
            ) from None
        except APIError as error:
            raise SystemExit(
                f"Images API request failed ({type(error).__name__})."
            ) from None
    if not result.data or not result.data[0].b64_json:
        raise SystemExit("Images API returned no image data.")
    try:
        data = base64.b64decode(result.data[0].b64_json, validate=True)
    except ValueError:
        raise SystemExit(
            "Invalid image encoding in a completed API response. Check usage before retrying."
        ) from None
    with args.output.open("xb") as output:
        output.write(data)
    try:
        with Image.open(args.output, formats=["PNG"]) as image:
            image.load()
            size = f"{image.width}x{image.height}"
            transparent = image.convert("RGBA").getchannel("A").getextrema()[0] < 255
    except OSError:
        die(
            f"Saved {args.output}, but the returned bytes could not be verified as PNG.",
            code=5,
        )
    print(f"Saved {args.output}; PNG {size}; transparent pixels: {transparent}")
    print(
        f"Requested {args.image_model}, quality {args.quality}; returned quality: {result.quality}"
    )
    if (
        args.size not in ("auto", size)
        or args.quality not in ("auto", result.quality)
        or (args.background == "transparent" and not transparent)
        or (args.background == "opaque" and transparent)
    ):
        die("Saved image has mismatched or unverified settings.", code=5)


if __name__ == "__main__":
    main()
