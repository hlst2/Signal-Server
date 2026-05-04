/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.entities;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonUnwrapped;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.Valid;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import javax.annotation.Nullable;
import org.signal.libsignal.protocol.IdentityKey;
import org.whispersystems.textsecuregcm.util.IdentityKeyAdapter;

/**
 * Registration request for the private-deployment endpoint that does not require phone-number verification.
 * The caller supplies a human-readable display name; the server derives a synthetic E164 internally and
 * never exposes it to clients.
 */
public record PrivateRegistrationRequest(
    @NotBlank
    @Size(min = 1, max = 64)
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = "Public display name for the account; used as the directory entry and as the seed for the internal account identifier")
    String displayName,

    @NotNull
    @Valid
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED)
    AccountAttributes accountAttributes,

    @NotNull
    @Valid
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = "ACI-associated identity key, base64-encoded")
    @JsonSerialize(using = IdentityKeyAdapter.Serializer.class)
    @JsonDeserialize(using = IdentityKeyAdapter.Deserializer.class)
    IdentityKey aciIdentityKey,

    @NotNull
    @Valid
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = "PNI-associated identity key, base64-encoded")
    @JsonSerialize(using = IdentityKeyAdapter.Serializer.class)
    @JsonDeserialize(using = IdentityKeyAdapter.Deserializer.class)
    IdentityKey pniIdentityKey,

    @NotNull
    @Valid
    @JsonUnwrapped
    @JsonProperty
    DeviceActivationRequest deviceActivationRequest) {

  public boolean isEverySignedKeyValid(@Nullable final String userAgent) {
    if (deviceActivationRequest().aciSignedPreKey() == null ||
        deviceActivationRequest().pniSignedPreKey() == null ||
        deviceActivationRequest().aciPqLastResortPreKey() == null ||
        deviceActivationRequest().pniPqLastResortPreKey() == null) {
      return false;
    }

    return PreKeySignatureValidator.validatePreKeySignatures(aciIdentityKey(),
            List.of(deviceActivationRequest().aciSignedPreKey(), deviceActivationRequest().aciPqLastResortPreKey()),
            userAgent, "register-private")
        && PreKeySignatureValidator.validatePreKeySignatures(pniIdentityKey(),
            List.of(deviceActivationRequest().pniSignedPreKey(), deviceActivationRequest().pniPqLastResortPreKey()),
            userAgent, "register-private");
  }

  @AssertTrue
  @Schema(hidden = true)
  boolean isExactlyOneMessageDeliveryChannel() {
    if (deviceActivationRequest == null || accountAttributes == null) {
      return false;
    }
    if (accountAttributes.getFetchesMessages()) {
      return deviceActivationRequest().apnToken().isEmpty() && deviceActivationRequest().gcmToken().isEmpty();
    } else {
      return deviceActivationRequest().apnToken().isPresent() ^ deviceActivationRequest().gcmToken().isPresent();
    }
  }
}
