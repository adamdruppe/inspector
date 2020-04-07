import arsd.jsvar;

import std.stdio;
import std.file;

void main(string[] args) {
	var a = var.fromJson(readText(args[1]));
	auto context = new JsonAnalyzerContext();
	auto answer = structsFromJson(a, context).toString();
	writeln(answer);
}

class JsonAnalyzerContext {
	static class JsonType {
		JsonType commonType(JsonType type) {
			if(typeid(type) == typeid(this))
				return type; // same class == match
			if(type == this)
				return this; // structural equality also equals match
			return JsonVar.singleton;
		}

		override string toString() {
			return toBasicString(0);
		}

		final string indent(int indentationLevel, string s) {
			if(indentationLevel == 0)
				return s;

			string magic;
			foreach(i; 0 .. indentationLevel)
				magic ~= "\t";

			import std.array;
			return magic ~ s;// replace(s, "\n", "\n" ~ magic);
		}

		string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "var");
		}
	}

	static class JsonArray : JsonType {
		this(JsonType of) {
			assert(of !is null);
			arrayOf = of;
		}

		JsonType arrayOf;
		override JsonType commonType(JsonType t) {
			if(auto array = cast(JsonArray) t) {
				return new JsonArray(arrayOf.commonType(array.arrayOf));
			} else if(auto n = cast(JsonNull) t) {
				return this;
			}
			return super.commonType(t);
		}

		override string toBasicString(int indentationLevel) {
			return arrayOf.toBasicString(indentationLevel) ~ "[]";
		}
	}

	static class JsonObject : JsonType {
		JsonType[string] members;

		JsonObject[string] memberStructs;

		bool nullable;

		override string toBasicString(int indentationLevel) {
			string code = indent(indentationLevel, (nullable ? "@nullable " : "") ~ "struct {\n");

			foreach(k, v; members) {
				code ~= v.toBasicString(indentationLevel + 1) ~ " " ~ k ~ ";\n";
			}

			code ~= indent(indentationLevel, "}");
			return code;
		}

		void addMember(string name, JsonType type) {
			if(auto ptr = name in members) {
				(*ptr) = ptr.commonType(type);
			} else
				members[name] = type;
		}

		override JsonType commonType(JsonType type) {
			if(cast(JsonNull) type) {
				this.nullable = true;
				return this;
			}
			return super.commonType(type);
		}
	}

	static class JsonInteger : JsonType {
		__gshared static typeof(this) singleton = new JsonInteger();

		override JsonType commonType(JsonType type) {
			if(auto dbl = cast(JsonFloat) type)
				return dbl; // double is the common type
			return super.commonType(type);
		}

		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "long");
		}
	}
	static class JsonFloat : JsonType {
		__gshared static typeof(this) singleton = new JsonFloat();
		override JsonType commonType(JsonType type) {
			if(auto i = cast(JsonInteger) type)
				return this; // double is the most common type of long and double
			return super.commonType(type);
		}
		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "double");
		}
	}
	static class JsonBoolean : JsonType {
		__gshared static typeof(this) singleton = new JsonBoolean();
		// true/false could implicitly convert to string or int, but
		// it really shouldn't. If that happens in the json, we'll just fall
		// back on null.

		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "bool");
		}
	}
	static class JsonNull : JsonType {
		__gshared static typeof(this) singleton = new JsonNull();
		override JsonType commonType(JsonType type) {
			// strings and arrays can be null in D too, so we
			// return them if possible
			if(auto str = cast(JsonString) type)
				return str;
			if(auto arr = cast(JsonArray) type)
				return arr;

			// however, since json objects are represented as structs,
			// they cannot be null!
			if(auto obj = cast(JsonObject) type) {
				obj.nullable = true;
				return obj;
			}
			return super.commonType(type);
		}

		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "typeof(null)");
		}
	}
	static class JsonString : JsonType {
		__gshared static typeof(this) singleton = new JsonString();
		override JsonType commonType(JsonType t) {
			if(auto n = cast(JsonNull) t) {
				return this;
			}
			return super.commonType(t);
		}

		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "string");
		}
	}
	static class JsonFunction : JsonType {
		__gshared static typeof(this) singleton = new JsonFunction();
		// this should never happen!
		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "typeof(null) /* function */");
		}
	}
	static class JsonVar : JsonType {
		__gshared static typeof(this) singleton = new JsonVar();
		// this is the supertype of everything
		override string toBasicString(int indentationLevel) {
			return indent(indentationLevel, "var");
		}
	}

	JsonObject findObject(string name) {
		if(auto it = name in objectTypes)
			return *it;
		auto i = new JsonAnalyzerContext.JsonObject();
		objectTypes[name] = i;
		return i;
	}

	JsonObject[string] objectTypes;
}

/// This analyzes a JSON input and tries to return matching static D types,
/// as a code string. It assumes that all members of an array have a common
/// type and all elements have the same members as the first one.
JsonAnalyzerContext.JsonType structsFromJson(var input, JsonAnalyzerContext context, JsonAnalyzerContext.JsonType suggestedType = null, string contextName = null) {
	final switch(input.payloadType()) {
		case var.Type.Object:
			if(input == null)
				return JsonAnalyzerContext.JsonNull.singleton;

			auto objSuggestion = cast(JsonAnalyzerContext.JsonObject) suggestedType;
			auto type = objSuggestion ? objSuggestion : context.findObject(contextName);

			foreach(k, v; input) {
				auto name = k.get!string;
				type.addMember(name, structsFromJson(v, context, null, contextName ~ "." ~ name));
			}

			return type;
		case var.Type.Array:
			JsonAnalyzerContext.JsonType common = null;
			foreach(v; input) {
				auto t = structsFromJson(v, context, common, contextName);
				if(common is null)
					common = t;
				else
					common = common.commonType(t);
			}
			if(common is null)
				common = JsonAnalyzerContext.JsonVar.singleton;
			return new JsonAnalyzerContext.JsonArray(common);
		case var.Type.String:
			return JsonAnalyzerContext.JsonString.singleton;
		case var.Type.Integral:
			return JsonAnalyzerContext.JsonInteger.singleton;
		case var.Type.Floating:
			return JsonAnalyzerContext.JsonFloat.singleton;
		case var.Type.Boolean:
			return JsonAnalyzerContext.JsonBoolean.singleton;
		case var.Type.Function:
			return JsonAnalyzerContext.JsonFunction.singleton;
	}
}
