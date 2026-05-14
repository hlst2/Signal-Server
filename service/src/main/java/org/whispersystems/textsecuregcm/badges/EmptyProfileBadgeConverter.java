/*
 * Copyright 2026 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.badges;

import java.util.List;
import java.util.Locale;
import org.whispersystems.textsecuregcm.entities.Badge;
import org.whispersystems.textsecuregcm.storage.AccountBadge;

public class EmptyProfileBadgeConverter implements ProfileBadgeConverter {

  @Override
  public List<Badge> convert(final List<Locale> acceptableLanguages,
      final List<AccountBadge> accountBadges,
      final boolean isSelf) {
    return List.of();
  }
}
