"""Trains the residual nowcast model and exports it to TFLite.

The model maps 4 motion-aligned history frames to the 5 lead-time frames,
all in the latest observation's Lagrangian frame (see build_dataset.py).
The reference to beat is Lagrangian persistence — predicting the latest
frame unchanged for every lead — which is exactly what the in-app advection
does before its heuristic fades. Any skill over that baseline is new
information the app cannot currently produce.

Samples are streamed from disk per batch (tf.data), so the dataset can be
much larger than RAM.

Usage:
  python train.py [--data data/samples] [--epochs 30] [--batch 8]
      [--val-fraction 0.15] [--export models/nowcast_residual.tflite]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers

import common

N_IN = len(common.FRAME_OFFSETS_MIN)
N_OUT = len(common.LEADS_MIN)
SIZE = common.MATCH_SIZE

# Echo pixels are rare (a few % of the domain); without upweighting them the
# model learns to predict zero everywhere.
ECHO_WEIGHT = 8.0


def sample_to_xy(path: Path) -> tuple[np.ndarray, np.ndarray]:
    with np.load(path) as z:
        inputs = z["inputs"].astype(np.float32) / 255.0
        targets = z["targets"].astype(np.float32) / 255.0
        valid = (
            np.unpackbits(z["valid"])[: targets.size]
            .reshape(targets.shape)
            .astype(np.float32)
        )
    weight = valid * (1.0 + ECHO_WEIGHT * np.maximum(targets, inputs[-1:] > 0))
    x = inputs.transpose(1, 2, 0)
    # Weights ride along as extra channels; the loss splits them off.
    y = np.concatenate([targets, weight]).transpose(1, 2, 0)
    return x, y


def make_dataset(paths: list[Path], batch: int, shuffle: bool) -> tf.data.Dataset:
    ds = tf.data.Dataset.from_tensor_slices([str(p) for p in paths])
    if shuffle:
        ds = ds.shuffle(len(paths), reshuffle_each_iteration=True)

    def load(p):
        x, y = tf.numpy_function(
            lambda b: sample_to_xy(Path(b.decode())), [p], (tf.float32, tf.float32)
        )
        x.set_shape((SIZE, SIZE, N_IN))
        y.set_shape((SIZE, SIZE, 2 * N_OUT))
        return x, y

    return (
        ds.map(load, num_parallel_calls=tf.data.AUTOTUNE)
        .batch(batch)
        .prefetch(tf.data.AUTOTUNE)
    )


def weighted_mae(y_true: tf.Tensor, y_pred: tf.Tensor) -> tf.Tensor:
    target = y_true[..., :N_OUT]
    weight = y_true[..., N_OUT:]
    err = tf.abs(target - y_pred) * weight
    return tf.reduce_sum(err) / (tf.reduce_sum(weight) + 1e-6)


def conv_block(x, filters):
    x = layers.Conv2D(filters, 3, padding="same", activation="relu")(x)
    return layers.Conv2D(filters, 3, padding="same", activation="relu")(x)


def build_model() -> tf.keras.Model:
    inp = layers.Input((SIZE, SIZE, N_IN))
    c1 = conv_block(inp, 24)
    c2 = conv_block(layers.MaxPool2D()(c1), 48)
    c3 = conv_block(layers.MaxPool2D()(c2), 96)
    c4 = conv_block(layers.MaxPool2D()(c3), 128)
    u3 = conv_block(layers.Concatenate()([layers.UpSampling2D()(c4), c3]), 96)
    u2 = conv_block(layers.Concatenate()([layers.UpSampling2D()(u3), c2]), 48)
    u1 = conv_block(layers.Concatenate()([layers.UpSampling2D()(u2), c1]), 24)
    out = layers.Conv2D(N_OUT, 1, activation="sigmoid")(u1)
    return tf.keras.Model(inp, out)


def persistence_baseline(paths: list[Path]) -> float:
    """Weighted MAE of Lagrangian persistence (latest frame repeated)."""
    num = den = 0.0
    for p in paths:
        x, y = sample_to_xy(p)
        pred = np.repeat(x[..., -1:], N_OUT, axis=-1)
        num += float((np.abs(y[..., :N_OUT] - pred) * y[..., N_OUT:]).sum())
        den += float(y[..., N_OUT:].sum())
    return num / (den + 1e-6)


def export_tflite(model: tf.keras.Model, path: Path) -> None:
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(converter.convert())
    print(f"exported {path} ({path.stat().st_size / 1e6:.2f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="data/samples")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--export", default="models/nowcast_residual.tflite")
    parser.add_argument(
        "--resume",
        action="store_true",
        help="continue from the models/nowcast_residual.keras checkpoint "
        "instead of fresh weights (optimizer state restarts)",
    )
    args = parser.parse_args()

    paths = sorted(Path(args.data).glob("*.npz"))
    if not paths:
        raise SystemExit(f"no samples under {args.data}")
    # Split by time, not randomly: patches from the same hour are nearly
    # identical, so a random split leaks the training set into validation.
    n_val = max(1, int(len(paths) * args.val_fraction))
    train_paths, val_paths = paths[:-n_val], paths[-n_val:]
    print(f"{len(train_paths)} train / {len(val_paths)} val samples")

    baseline = persistence_baseline(val_paths)
    print(f"persistence baseline (val): {baseline:.5f}")

    checkpoint = Path("models/nowcast_residual.keras")
    if args.resume and checkpoint.exists():
        model = tf.keras.models.load_model(
            checkpoint, custom_objects={"weighted_mae": weighted_mae}
        )
        print(f"resumed from {checkpoint}")
    else:
        model = build_model()
    model.compile(optimizer=tf.keras.optimizers.Adam(1e-3), loss=weighted_mae)
    model.summary(line_length=90)
    model.fit(
        make_dataset(train_paths, args.batch, shuffle=True),
        validation_data=make_dataset(val_paths, args.batch, shuffle=False),
        epochs=args.epochs,
        callbacks=[
            tf.keras.callbacks.ReduceLROnPlateau(patience=3, factor=0.5),
            tf.keras.callbacks.EarlyStopping(patience=6, restore_best_weights=True),
            # Best-so-far survives a killed run; a completed fit overwrites
            # this with the same weights via model.save below.
            tf.keras.callbacks.ModelCheckpoint(
                "models/nowcast_residual.keras",
                save_best_only=True,
            ),
        ],
    )
    print(f"persistence baseline (val): {baseline:.5f}")

    model.save("models/nowcast_residual.keras")
    if args.export:
        export_tflite(model, Path(args.export))


if __name__ == "__main__":
    main()
