import Foundation

/// Remove segredos conhecidos (tokens OAuth, chaves de stream, cabeçalhos de
/// autorização) de mensagens antes que elas cheguem a qualquer log.
///
/// É uma rede de segurança, não uma licença: o código continua proibido de
/// registrar segredos deliberadamente.
public enum Redactor {
    public static let mask = "‹redacted›"

    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // chave=valor ou "chave": "valor" para nomes sensíveis
            #"(?i)("?(?:access_token|refresh_token|id_token|client_secret|api_key|apikey|password|stream_key|streamkey|token)"?\s*[:=]\s*"?)([^"&\s,}]+)"#,
            // Authorization: Bearer xxx
            #"(?i)(bearer\s+)([A-Za-z0-9\-._~+/]+=*)"#,
            // Tokens de acesso Google (ya29.) e refresh tokens (1//)
            #"()(ya29\.[A-Za-z0-9\-_]+)"#,
            #"()(1//[A-Za-z0-9\-_]{10,})"#,
            // URLs RTMP com chave de stream no caminho
            #"(?i)(rtmps?://[^\s/]+/[^\s/]+/)([^\s]+)"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func redact(_ message: String) -> String {
        var result = message
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "$1\(mask)")
        }
        return result
    }
}
