/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */
package org.whispersystems.textsecuregcm.util;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

public final class SyntheticE164 {

  // ITU-reserved country code that is unassigned to any region; will never collide with a real number.
  private static final String COUNTRY_CODE_PREFIX = "+999";
  private static final long MAX_NATIONAL_NUMBER = 1_000_000_000_000L;

  private SyntheticE164() {}

  public static String forName(final String name) {
    final byte[] hash;
    try {
      hash = MessageDigest.getInstance("SHA-256")
          .digest(name.toLowerCase().getBytes(StandardCharsets.UTF_8));
    } catch (final NoSuchAlgorithmException e) {
      throw new AssertionError("SHA-256 not available", e);
    }

    long value = 0L;
    for (int i = 0; i < 8; i++) {
      value = (value << 8) | (hash[i] & 0xFFL);
    }
    final long national = Math.floorMod(value, MAX_NATIONAL_NUMBER);
    return COUNTRY_CODE_PREFIX + String.format("%012d", national);
  }
}
