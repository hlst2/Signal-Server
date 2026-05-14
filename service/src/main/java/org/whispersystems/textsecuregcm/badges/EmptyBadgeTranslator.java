/*
 * Copyright 2026 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.badges;

import java.util.List;
import java.util.Locale;
import org.whispersystems.textsecuregcm.entities.Badge;

public class EmptyBadgeTranslator implements BadgeTranslator {

  @Override
  public Badge translate(final List<Locale> acceptableLanguages, final String badgeId) {
    return null;
  }
}
