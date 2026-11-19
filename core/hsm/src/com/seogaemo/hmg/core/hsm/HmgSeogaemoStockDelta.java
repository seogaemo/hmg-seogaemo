package com.seogaemo.hmg.core.hsm;

import java.io.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.zip.GZIPInputStream;

/** Reconstructs an HSD1 delta in a private staging file. The runtime commits it. */
public final class HmgSeogaemoStockDelta {
    private static final int LIMIT = 8 * 1024 * 1024;
    private HmgSeogaemoStockDelta() {}

    private static byte[] read(DataInputStream in, int length) throws IOException {
        if (length < 0 || length > LIMIT) throw new IOException("invalid length");
        byte[] bytes = new byte[length];
        in.readFully(bytes);
        return bytes;
    }

    private static void apply(File source, DataInputStream delta, File dest) throws Exception {
        if (delta.readInt() != 0x48534431) throw new IOException("invalid delta");
        byte[] expectedStock = read(delta, 32);
        byte[] expectedOutput = read(delta, 32);
        int sourceSize = delta.readInt(), resultSize = delta.readInt(), blocks = delta.readInt();
        if (!source.isFile() || source.length() != sourceSize || resultSize <= 0 || resultSize > LIMIT
                || blocks <= 0 || blocks > 65536) throw new IOException("unexpected sizes");
        DataInputStream input = new DataInputStream(new FileInputStream(source));
        byte[] stock;
        try {
            stock = read(input, sourceSize);
            if (input.read() != -1) throw new IOException("source grew");
        } finally { input.close(); }
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        if (!Arrays.equals(expectedStock, sha.digest(stock))) throw new IOException("stock differs");
        byte[] output = new byte[resultSize];
        int written = 0;
        long offset = 0;
        for (int n = 0; n < blocks; n++) {
            int add = delta.readInt(), copy = delta.readInt(), seek = delta.readInt();
            if (add < 0 || copy < 0 || (long) add + copy > resultSize - written)
                throw new IOException("invalid delta span");
            delta.readFully(output, written, add);
            for (int i = 0; i < add; i++) {
                long index = offset + i;
                if (index >= 0 && index < stock.length) output[written + i] += stock[(int) index];
            }
            written += add;
            delta.readFully(output, written, copy);
            written += copy;
            offset += (long) add + seek;
        }
        if (written != resultSize || delta.read() != -1 || !Arrays.equals(expectedOutput, sha.digest(output)))
            throw new IOException("result differs");
        if (!dest.createNewFile()) throw new IOException("destination exists");
        FileOutputStream out = new FileOutputStream(dest);
        try { out.write(output); out.getFD().sync(); } finally { out.close(); }
    }

    public static void main(String[] args) {
        try {
            if (args.length != 3) throw new IOException("usage: STOCK DELTA STAGED");
            DataInputStream delta = new DataInputStream(new BufferedInputStream(
                    new GZIPInputStream(new FileInputStream(args[1]))));
            try { apply(new File(args[0]), delta, new File(args[2])); } finally { delta.close(); }
        } catch (Exception e) {
            System.err.println("stock delta: " + e.getMessage());
            System.exit(1);
        }
    }
}
