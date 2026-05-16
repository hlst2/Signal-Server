/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.configuration;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonTypeName;
import jakarta.validation.constraints.NotBlank;
import java.net.URI;
import javax.annotation.Nullable;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;
import software.amazon.awssdk.services.s3.S3AsyncClientBuilder;

@JsonTypeName("default")
public class DefaultS3AsyncClientFactory implements S3AsyncClientFactory {

  @NotBlank
  @JsonProperty
  String region;

  @Nullable
  @JsonProperty
  URI endpointOverride;

  @Override
  public S3AsyncClient buildAsyncClient(final AwsCredentialsProvider credentialsProvider, final String bucketName) {
    final S3AsyncClientBuilder builder = S3AsyncClient.builder()
        .credentialsProvider(credentialsProvider)
        .region(Region.of(region));
    if (endpointOverride != null) {
      builder.endpointOverride(endpointOverride);
    }
    return builder.build();
  }
}
