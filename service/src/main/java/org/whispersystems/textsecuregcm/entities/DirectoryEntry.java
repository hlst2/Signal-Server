/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.entities;

import io.swagger.v3.oas.annotations.media.Schema;
import java.util.UUID;
import javax.annotation.Nullable;

public record DirectoryEntry(
    @Schema(description = "ACI of the registered account")
    UUID aci,

    @Schema(description = "Public display name set at registration time, if any")
    @Nullable String displayName) {
}
