/*
 * Copyright 2024 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.configuration;

import static org.testcontainers.containers.localstack.LocalStackContainer.Service.S3;

import com.fasterxml.jackson.annotation.JsonTypeName;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import org.apache.commons.lang3.StringUtils;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.utility.DockerImageName;
import org.whispersystems.textsecuregcm.util.TestcontainersImages;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3AsyncClient;
import software.amazon.awssdk.services.s3.model.BucketAlreadyOwnedByYouException;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;

/**
 * Test-only {@link S3AsyncClientFactory} that boots a single LocalStack container on first use and exposes it as the S3
 * endpoint. The container is shared across the JVM; buckets requested by callers are created on demand.
 */
@JsonTypeName("local")
public class LocalS3AsyncClientFactory implements S3AsyncClientFactory {

  private static final DockerImageName LOCAL_STACK_IMAGE = DockerImageName.parse(TestcontainersImages.getLocalStack())
      .asCompatibleSubstituteFor(
          StringUtils.substringBefore(
              StringUtils.substringBefore(TestcontainersImages.getLocalStack(), "@"),
              ":"));

  private static final LocalStackContainer LOCAL_STACK = new LocalStackContainer(LOCAL_STACK_IMAGE)
      .withServices(S3)
      .withExposedPorts(4566);

  private static volatile boolean started = false;
  private static final ConcurrentMap<String, Boolean> createdBuckets = new ConcurrentHashMap<>();

  private static synchronized void startIfNeeded() {
    if (!started) {
      LOCAL_STACK.start();
      Runtime.getRuntime().addShutdownHook(new Thread(LOCAL_STACK::stop));
      started = true;
    }
  }

  @Override
  public S3AsyncClient buildAsyncClient(final AwsCredentialsProvider credentialsProvider, final String bucketName) {
    startIfNeeded();

    final S3AsyncClient client = S3AsyncClient.builder()
        .endpointOverride(LOCAL_STACK.getEndpoint())
        .credentialsProvider(StaticCredentialsProvider.create(
            AwsBasicCredentials.create(LOCAL_STACK.getAccessKey(), LOCAL_STACK.getSecretKey())))
        .region(Region.of(LOCAL_STACK.getRegion()))
        .build();

    createdBuckets.computeIfAbsent(bucketName, name -> {
      try {
        client.createBucket(CreateBucketRequest.builder().bucket(name).build()).join();
      } catch (final Exception e) {
        if (!(e.getCause() instanceof BucketAlreadyOwnedByYouException)) {
          throw new RuntimeException("Failed to create LocalStack bucket: " + name, e);
        }
      }
      return Boolean.TRUE;
    });

    return client;
  }
}
