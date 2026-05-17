/*
 * Copyright 2023 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.securestorage;

import static org.whispersystems.textsecuregcm.util.HeaderUtils.basicAuthHeader;

import com.google.common.annotations.VisibleForTesting;
import com.google.common.net.HttpHeaders;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.cert.CertificateException;
import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.ScheduledExecutorService;
import org.whispersystems.textsecuregcm.auth.ExternalServiceCredentials;
import org.whispersystems.textsecuregcm.auth.ExternalServiceCredentialsGenerator;
import org.whispersystems.textsecuregcm.configuration.SecureStorageServiceConfiguration;
import org.whispersystems.textsecuregcm.http.FaultTolerantHttpClient;
import org.whispersystems.textsecuregcm.util.HttpUtils;

/**
 * A client for sending requests to Signal's secure storage service on behalf of authenticated users.
 */
public class SecureStorageClient {

  private static final org.slf4j.Logger logger = org.slf4j.LoggerFactory.getLogger(SecureStorageClient.class);

  private final ExternalServiceCredentialsGenerator storageServiceCredentialsGenerator;
  private final URI deleteUri;
  private final FaultTolerantHttpClient httpClient;
  // server-private fork: true when secureStorageService.uri is not a real http(s):// endpoint, i.e.
  // this deployment is not running the auxiliary SVR-side secure-storage-service. All operations
  // short-circuit so AccountsManager.delete() (and any other caller) succeeds without trying to
  // POST/DELETE against a schemeless URI.
  private final boolean disabled;

  @VisibleForTesting
  static final String DELETE_PATH = "/v1/storage";

  public SecureStorageClient(final ExternalServiceCredentialsGenerator storageServiceCredentialsGenerator,
      final Executor executor, final
  ScheduledExecutorService retryExecutor, final SecureStorageServiceConfiguration configuration)
      throws CertificateException {
    this.storageServiceCredentialsGenerator = storageServiceCredentialsGenerator;
    final URI resolved = URI.create(configuration.uri()).resolve(DELETE_PATH);
    this.disabled = resolved.getScheme() == null;
    this.deleteUri = resolved;
    if (disabled) {
      logger.warn("SecureStorageClient disabled: secureStorageService.uri='{}' resolves to a URI without a scheme; "
          + "delete-account and related flows will skip the secure-storage-service call.", configuration.uri());
    }
    this.httpClient = FaultTolerantHttpClient.newBuilder("secure-storage", executor)
        .withCircuitBreaker(configuration.circuitBreakerConfigurationName())
        .withRetry(configuration.retryConfigurationName(), retryExecutor)
        .withVersion(HttpClient.Version.HTTP_1_1)
        .withConnectTimeout(Duration.ofSeconds(10))
        .withRedirect(HttpClient.Redirect.NEVER)
        .withSecurityProtocol(FaultTolerantHttpClient.SECURITY_PROTOCOL_TLS_1_3)
        .withTrustedServerCertificates(configuration.storageCaCertificates().toArray(new String[0]))
        .build();
  }

  public CompletableFuture<Void> deleteStoredData(final UUID accountUuid) {
    if (disabled) {
      // No secure-storage-service is running on this deployment; nothing to wipe.
      return CompletableFuture.completedFuture(null);
    }
    final ExternalServiceCredentials credentials = storageServiceCredentialsGenerator.generateForUuid(accountUuid);

    final HttpRequest request = HttpRequest.newBuilder()
        .uri(deleteUri)
        .DELETE()
        .header(HttpHeaders.AUTHORIZATION, basicAuthHeader(credentials))
        .build();

        return httpClient.sendAsync(request, HttpResponse.BodyHandlers.ofString()).thenApply(response -> {
            if (HttpUtils.isSuccessfulResponse(response.statusCode())) {
                return null;
            }

            throw new SecureStorageException("Failed to delete storage service data: " + response.statusCode());
        });
    }
}
