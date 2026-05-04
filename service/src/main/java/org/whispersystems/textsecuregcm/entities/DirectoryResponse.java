/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.entities;

import io.swagger.v3.oas.annotations.media.Schema;
import java.util.List;

public record DirectoryResponse(
    @Schema(description = "All registered accounts on this server")
    List<DirectoryEntry> entries) {
}
