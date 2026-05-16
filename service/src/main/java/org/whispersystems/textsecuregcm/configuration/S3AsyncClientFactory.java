/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.configuration;

import com.fasterxml.jackson.annotation.JsonTypeInfo;
import io.dropwizard.jackson.Discoverable;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.services.s3.S3AsyncClient;

@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "type", defaultImpl = DefaultS3AsyncClientFactory.class)
public interface S3AsyncClientFactory extends Discoverable {

  /**
   * Build an {@link S3AsyncClient}. The bucket name is passed so that local/test implementations may pre-create the
   * bucket against a stand-in S3 (LocalStack, MinIO, etc.). Production implementations may ignore it.
   */
  S3AsyncClient buildAsyncClient(AwsCredentialsProvider credentialsProvider, String bucketName);
}
