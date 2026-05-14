/*
 * Copyright 2026 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.badges;

import java.util.List;
import java.util.Locale;

public class EmptyLevelTranslator implements LevelTranslator {

  @Override
  public String translate(final List<Locale> acceptableLanguages, final String badgeId) {
    return "";
  }
}
