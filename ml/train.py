"""Trains the residual nowcast model and exports it to TFLite.

The model maps 4 motion-aligned history frames to the 5 lead-time frames,
all in the latest observation's Lagrangian frame (see build_dataset.py).
The reference to beat is Lagrangian persistence — predicting the latest
frame unchanged for every lead — which is exactly what the in-app advection
does before its heuristic fades. Any skill over that baseline is new
information the app cannot currently produce.

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


def load_samples(paths: list[Path]) -> tuple[np.ndarray, np.ndarray]:
    xs, ys = [], []
    for path in paths:
        with np.load(path) as z:
            inputs = z["inputs"].astype(np.float32) / 255.0
            targets = z["targets"].astype(np.float32) / 255.0
            valid = (
                np.unpackbits(z["valid"])[: targets.size]
                .reshape(targets.shape)
                .astype(np.float32)
            )
        weight = valid * (
            1.0 + ECHO_WEIGHT * np.maximum(targets, inputs[-1:] > 0)
        )
        xs.append(inputs.transpose(1, 2, 0))
        # Weights ride along as extra channels; the loss splits them off.
        ys.append(np.concatenate([targets, weight]).transpose(1, 2, 0))
    return np.stack(xs), np.stack(ys)


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


def persistence_loss(ys: np.ndarray, xs: np.ndarray) -> float:
    """Weighted MAE of Lagrangian persistence (latest frame repeated)."""
    pred = np.repeat(xs[..., -1:], N_OUT, axis=-1)
    target = ys[..., :N_OUT]
    weight = ys[..., N_OUT:]
    return float((np.abs(target - pred) * weight).sum() / (weight.sum() + 1e-6))


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
    args = parser.parse_args()

    paths = sorted(Path(args.data).glob("*.npz"))
    if not paths:
        raise SystemExit(f"no samples under {args.data}")
    # Split by time, not randomly: patches from the same hour are nearly
    # identical, so a random split leaks the training set into validation.
    n_val = max(1, int(len(paths) * args.val_fraction))
    train_paths, val_paths = paths[:-n_val], paths[-n_val:]
    print(f"{len(train_paths)} train / {len(val_paths)} val samples")

    x_train, y_train = load_samples(train_paths)
    x_val, y_val = load_samples(val_paths)
    print(f"persistence baseline (val): {persistence_loss(y_val, x_val):.5f}")

    model = build_model()
    model.compile(optimizer=tf.keras.optimizers.Adam(1e-3), loss=weighted_mae)
    model.summary(line_length=90)
    model.fit(
        x_train,
        y_train,
        validation_data=(x_val, y_val),
        epochs=args.epochs,
        batch_size=args.batch,
        callbacks=[
            tf.keras.callbacks.ReduceLROnPlateau(patience=3, factor=0.5),
            tf.keras.callbacks.EarlyStopping(patience=6, restore_best_weights=True),
        ],
    )
    print(f"persistence baseline (val): {persistence_loss(y_val, x_val):.5f}")

    if args.export:
        export_tflite(model, Path(args.export))


if __name__ == "__main__":
    main()
