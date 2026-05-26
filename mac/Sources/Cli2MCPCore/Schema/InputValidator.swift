import Foundation

public struct ValidationFailure: Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct ValidationResult: Equatable, Sendable {
    public var ok: Bool
    public var errors: [ValidationFailure]

    public init(ok: Bool, errors: [ValidationFailure]) {
        self.ok = ok
        self.errors = errors
    }
}

public enum InputValidator {
    public static func validate(_ input: [String: JSONValue], against schema: JSONSchema) -> ValidationResult {
        validate(.object(input), against: schema)
    }

    public static func validate(_ input: JSONValue, against schema: JSONSchema) -> ValidationResult {
        guard case .object(let object) = input else {
            return ValidationResult(ok: false, errors: [ValidationFailure(path: "(root)", message: "must be object")])
        }

        var errors: [ValidationFailure] = []

        for key in object.keys {
            if schema.properties[key] == nil {
                errors.append(
                    ValidationFailure(
                        path: "(root)",
                        message: "must NOT have additional properties (saw '\(key)')"
                    )
                )
            }
        }

        for key in schema.validationPropertyOrder {
            guard let property = schema.properties[key], let value = object[key] else {
                continue
            }

            checkProperty(path: "/\(key)", value: value, property: property, errors: &errors)
        }

        return ValidationResult(ok: errors.isEmpty, errors: errors)
    }

    public static func formatValidationErrors(_ errors: [ValidationFailure]) -> String {
        guard !errors.isEmpty else {
            return "input did not match the published schema"
        }

        return errors.map { "\($0.path) \($0.message)" }.joined(separator: "; ")
    }
}

private extension InputValidator {
    static func checkProperty(
        path: String,
        value: JSONValue,
        property: JSONSchemaProperty,
        errors: inout [ValidationFailure]
    ) {
        switch property.type {
        case "boolean":
            guard case .bool = value else {
                errors.append(ValidationFailure(path: path, message: "must be boolean"))
                return
            }
        case "number":
            guard case .number(let number) = value, number.isFinite else {
                errors.append(ValidationFailure(path: path, message: "must be number"))
                return
            }
        case "string":
            guard case .string(let string) = value else {
                errors.append(ValidationFailure(path: path, message: "must be string"))
                return
            }
            checkEnum(path: path, value: string, choices: property.enum, errors: &errors)
        case "array":
            guard case .array(let values) = value else {
                errors.append(ValidationFailure(path: path, message: "must be array"))
                return
            }
            checkArray(path: path, values: values, item: property.items, errors: &errors)
        default:
            return
        }
    }

    static func checkArray(
        path: String,
        values: [JSONValue],
        item: JSONSchemaArrayItem?,
        errors: inout [ValidationFailure]
    ) {
        let itemType = item?.type ?? "string"

        for (index, value) in values.enumerated() {
            let itemPath = "\(path)/\(index)"

            switch itemType {
            case "string":
                guard case .string(let string) = value else {
                    errors.append(ValidationFailure(path: itemPath, message: "must be string"))
                    continue
                }
                checkEnum(path: itemPath, value: string, choices: item?.enum, errors: &errors)
            case "number":
                guard case .number(let number) = value, number.isFinite else {
                    errors.append(ValidationFailure(path: itemPath, message: "must be number"))
                    continue
                }
            case "boolean":
                guard case .bool = value else {
                    errors.append(ValidationFailure(path: itemPath, message: "must be boolean"))
                    continue
                }
            default:
                continue
            }
        }
    }

    static func checkEnum(
        path: String,
        value: String,
        choices: [String]?,
        errors: inout [ValidationFailure]
    ) {
        guard let choices, !choices.contains(value) else {
            return
        }

        errors.append(
            ValidationFailure(
                path: path,
                message: "must be one of: \(choices.map(Self.jsonStringLiteral).joined(separator: ", "))"
            )
        )
    }

    static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return #""\#(value)""#
        }
        return encoded
    }
}

private extension JSONSchema {
    var validationPropertyOrder: [String] {
        propertyOrder + properties.keys.filter { !propertyOrder.contains($0) }
    }
}
