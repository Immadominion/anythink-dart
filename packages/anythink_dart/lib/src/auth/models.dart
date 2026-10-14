import '../errors.dart';
import '../json.dart';

/// The opaque token pair. Never include this object in application diagnostics.
final class Session {
  const Session({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  factory Session.fromTokenResponse(Object? value, DateTime receivedAt) {
    final json = objectFromJson(value, 'session');
    final access = stringFromJson(json['access_token'], 'access_token');
    final refresh = stringFromJson(json['refresh_token'], 'refresh_token');
    final lifetime = intFromJson(json['expires_in'], 'expires_in');
    // Bound arithmetic before constructing a Duration. Anythink documents a
    // 30-minute access lifetime; one year leaves ample room for future policy
    // changes without accepting overflow or nonsensical server metadata.
    if (access.isEmpty ||
        refresh.isEmpty ||
        lifetime <= 0 ||
        lifetime > 365 * 24 * 60 * 60) {
      throw const ProtocolException('The session response is incomplete.');
    }
    return Session(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: receivedAt.toUtc().add(Duration(seconds: lifetime)),
    );
  }

  @override
  String toString() => 'Session(credentials: [redacted])';
}

/// Identity returned by the server. Access tokens are never decoded for identity.
final class AnythinkUser {
  AnythinkUser.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'user.id'),
      gid = stringFromJson(json['gid'], 'user.gid'),
      email = optionalStringFromJson(json['email'], 'user.email'),
      firstName = optionalStringFromJson(json['first_name'], 'user.first_name'),
      lastName = optionalStringFromJson(json['last_name'], 'user.last_name'),
      data = Map.unmodifiable(json);
  final int id;
  final String gid;
  final String? email;
  final String? firstName;
  final String? lastName;
  final JsonObject data;
  @override
  String toString() => 'AnythinkUser(id: $id)';
}

enum AuthStatus {
  signedOut,
  restoring,
  authenticating,
  authenticated,
  temporarilyUnavailable,
  reauthenticationRequired,
}

/// Credential-free observable state. A valid session can exist while [user]
/// is still loading; a failed identity request never leaves the previous user.
final class AuthState {
  const AuthState(this.status, {this.user, this.error});
  final AuthStatus status;
  final AnythinkUser? user;
  final AnythinkException? error;
  @override
  String toString() => 'AuthState(${status.name})';
}

/// Local sign-out completes independently from best-effort remote revocation.
final class SignOutResult {
  const SignOutResult({required this.remoteRevoked, this.remoteError});
  final bool remoteRevoked;
  final AnythinkException? remoteError;
}

enum NativeProvider { apple, google, linkedin }

enum WebProvider { apple, google, github, linkedin }

/// Optional signup attribution captured by the web authorise flow for a newly
/// created user. Values are sent unchanged as individually encoded query fields.
/// No redirect, provider or authentication parameters can be overridden here.
final class SignupAttribution {
  const SignupAttribution({
    this.utmSource,
    this.utmMedium,
    this.utmCampaign,
    this.utmTerm,
    this.utmContent,
    this.referrer,
    this.signupCountry,
  });

  final String? utmSource;
  final String? utmMedium;
  final String? utmCampaign;
  final String? utmTerm;
  final String? utmContent;
  final String? referrer;
  final String? signupCountry;

  Map<String, String> toQueryParameters() => Map.unmodifiable({
    'utm_source': ?utmSource,
    'utm_medium': ?utmMedium,
    'utm_campaign': ?utmCampaign,
    'utm_term': ?utmTerm,
    'utm_content': ?utmContent,
    'referrer': ?referrer,
    'signup_country': ?signupCountry,
  });
}

/// A provider enabled for web sign-in. Native-only providers may be absent.
/// The name remains a string so new server providers do not break discovery.
final class AuthProviderInfo {
  AuthProviderInfo.fromJson(JsonObject json)
    : provider = stringFromJson(json['provider'], 'provider'),
      displayName = stringFromJson(json['display_name'], 'display_name'),
      icon = optionalStringFromJson(json['icon'], 'icon'),
      data = Map.unmodifiable(json);
  final String provider;
  final String displayName;
  final String? icon;
  final JsonObject data;
}
