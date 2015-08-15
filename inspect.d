/**
	This is an interactive json inspector program.

	By Adam D. Ruppe, December 22, 2014.

	json -> struct analyzer added Aug 11, 2015.
*/


import terminal;

import arsd.script;
import arsd.http2;

import std.stdio;

string lastLine;
HttpClient client;

string[128] clicks;

var makeClientProxy() {
	auto client = .client;
	var obj = var.emptyObject;

	obj.authorization._object = new PropertyPrototype(
		() => var(client.authorization),
		(var t) {client.authorization = t.toString(); });
	obj.userAgent._object = new PropertyPrototype(
		() => var(client.userAgent),
		(var t) {client.userAgent = t.toString(); });

	return obj;
}



// helper for structsFromJson
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
		break;
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
		break;
		case var.Type.String:
			return JsonAnalyzerContext.JsonString.singleton;
		break;
		case var.Type.Integral:
			return JsonAnalyzerContext.JsonInteger.singleton;
		break;
		case var.Type.Floating:
			return JsonAnalyzerContext.JsonFloat.singleton;
		break;
		case var.Type.Boolean:
			return JsonAnalyzerContext.JsonBoolean.singleton;
		break;
		case var.Type.Function:
			return JsonAnalyzerContext.JsonFunction.singleton;
		break;
	}
}

/**
	Arguments:

		a .json file will be loaded into the buffer and the variable "obj" if given
		a URL will be loaded into the buffer and the variable "response" if given

		If you give multiple .json files or urls, it will do them all, but only the last
		one will actually be displayed and loaded in the variable (since it overwrites the
		last ones)

		any .js file given will be interpreted automatically at startup if given.
*/
void main(string[] args) {
	auto terminal = Terminal(ConsoleOutputType.cellular);
	terminal.setTitle("Inspector");
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

	auto client = new HttpClient();
	.client = client;

	auto lineGetter = new LineGetter(&terminal, "json-inspect");
	scope(exit) lineGetter.dispose();
	lineGetter.prompt = "> ";
	terminal.moveTo(0, terminal.height - 1);
	lineGetter.startGettingLine();

	bool running = true;

	var globals = var.emptyObject;

	int pos;

	globals.inspectionStack = [];
	globals.pushInspection = delegate var(var i) {
		if(pos != globals.inspectionStack.length.get!int - 1)
			globals.inspectionStack = globals.inspectionStack[0 .. pos + 1];
		globals.inspectionStack ~= i;
		globals.inspecting = i;
		pos = globals.inspectionStack.length.get!int - 1;
		return i;
	};

	globals.toStaticType = delegate var(var i) {
		auto context = new JsonAnalyzerContext();
		return var(structsFromJson(i, context).toString());
	};

	globals.popInspection = delegate var() {
		var i = globals.inspectionStack[$-1];
		globals.inspectionStack = globals.inspectionStack[0 .. $-1];
		pos--;
		return i;
	};

	globals.loadJsonFile = delegate var(string name) {
		import std.file;
		return var.fromJson(readText(name));
	};

	globals.saveJsonFile = delegate var(string name, var obj) {
		import std.file;
		write(name, obj.toJson());
		return obj;
	};

	globals.exit = delegate() {
		running = false;
	};

	globals["httpClient"] = makeClientProxy;

	var delegate(string, var) httpRequestFactory(HttpVerb method) {
		return delegate var(string path, var data) {
			auto request = client.navigateTo(Uri(path), method);
			if(data) {
				auto send = data.toJson();
				request.requestParameters.bodyData = cast(ubyte[]) send;
				request.requestParameters.headers ~= "Content-Type: application/json";
			}
			request.send();
			auto got = request.waitForCompletion();
			var answer = var(got);

			try {
				answer.reply = var.fromJson(got.contentText);
			} catch(Exception e) {
				answer.reply = var(got.contentText);
			}

			return answer;
		};
	}

	globals["get"] = httpRequestFactory(HttpVerb.GET);
	globals["post"] = httpRequestFactory(HttpVerb.POST);
	globals["put"] = httpRequestFactory(HttpVerb.PUT);
	globals["patch"] = httpRequestFactory(HttpVerb.PATCH);
	globals["delete"] = httpRequestFactory(HttpVerb.DELETE);

	void executeLine(string line) {
		try {
			drawInspectionWindow(&terminal, globals.pushInspection()(interpret(line, globals)));
		} catch(Exception e) {
			drawInspectionWindow(&terminal, var(e.msg));
		}
		terminal.moveTo(0, terminal.height - 1);
		lineGetter.startGettingLine();
	}

	void handleEvent(InputEvent event) {
		switch(event.type) {
			case InputEvent.Type.MouseEvent:
				auto ev = event.get!(InputEvent.Type.MouseEvent);
				if(ev.eventType == MouseEvent.Type.Pressed) {
					if(ev.y == 0) {
						// clicks on the top bar
						if(ev.x >= 0 && ev.x < 4) {
							// back button
							if(pos) {
								pos--;
								globals.inspecting = globals.inspectionStack[pos];
								drawInspectionWindow(&terminal, globals.inspectionStack[pos]);
							}
							break;
						}
						if(ev.x >= 5 && ev.x < 5+4) {
							// forward button

							if(pos + 1 < globals.inspectionStack.length) {
								pos++;
								globals.inspecting = globals.inspectionStack[pos];
								drawInspectionWindow(&terminal, globals.inspectionStack[pos]);
							}
							break;
						}
					} else {
						if(clicks[ev.y].length)
							executeLine("inspecting["~clicks[ev.y]~"];");
						// click on the main window
						break;
					}

				}

				goto pass_on;
			case InputEvent.Type.CharacterEvent:
				auto ev = event.get!(InputEvent.Type.CharacterEvent);
				if(ev.character == ('x' - 'a' + 1)) {
					// ctrl+x is a shortcut to open a json literal in the script lang
					lineGetter.addString("json!q{");
					lineGetter.redraw();
					break;
				}
				goto pass_on;
			default:
			pass_on:
				try
				if(!lineGetter.workOnLine(event)) {
					auto line = lineGetter.finishGettingLine();
					lastLine = line;
					line ~= ";"; // just so you don't have to always do it yourself

					executeLine(line);
				}
				catch(Exception e)
					running = false;
		}
	}

	executeLine(`"Inspector version 1.0";`);

	foreach(arg; args[1 .. $]) {
		import std.algorithm;
		if(endsWith(arg, ".js")) {
			import std.file;
			interpret(readText(arg), globals);
		} else if(endsWith(arg, ".json")) {
			executeLine("loadJsonFile("~var(arg).toJson()~");");
		} else if(startsWith(arg, "http://")) {
			executeLine("get("~var(arg).toJson()~");");
		}
	}

	while(running) {
		auto event = input.nextEvent();
		handleEvent(event);
	}

}

void drawInspectionWindow(Terminal* terminal, var inspecting) {
	terminal.clear();

	terminal.write("[<<] [>>] | ");
	terminal.write(client.location);
	terminal.write(" | ");
	terminal.writeln(lastLine);

	foreach(i; 0 .. terminal.width)
		terminal.write("-");

	//terminal.moveTo(0, 2);

	clicks[] = null;

	drawItem(terminal, inspecting, 0);

	terminal.flush();
}

// This pretty prints a JSON object and remembers where the items are on screen so you
// can click on them too.
void drawItem(Terminal* terminal, var inspecting, int indentLevel, bool child = false) {
	void indent() {
		terminal.write("\n");
		foreach(i; 0 .. indentLevel)
			terminal.write("  ");
	}

	final switch(inspecting.payloadType) {
		case var.Type.Object:
			if(inspecting == null)
				terminal.write("null");
			else {
				terminal.write("{");
				indentLevel++;
				int count = cast(int) inspecting._object._properties.length;
				int showing = 0;
				foreach(k, v; inspecting) {
					indent();
					terminal.write(k);
					clicks[terminal.cursorY] = "\"" ~ k.get!string ~ "\"";
					terminal.write(": ");
					drawItem(terminal, v, indentLevel, true);

					showing++;
					if(indentLevel != 1 && showing == 3 && showing < count) {
						indent();
						terminal.writef(" ... %d more members ...", count - showing);
						break;
					}

				}
				indentLevel--;
				indent();
				terminal.write("}");
			}
		break;
		case var.Type.String:
			auto disp = inspecting.toString();
			if(indentLevel && disp.length > 40)
				disp = disp[0 .. 40] ~ "[...]";
			terminal.write("\"", disp, "\"");
		break;
		case var.Type.Array:
			terminal.write("[");
			if(!indentLevel) {
				indentLevel++;
				foreach(idx, item; inspecting) {
					indent();
					import std.conv; clicks[terminal.cursorY] = to!string(idx);
					drawItem(terminal, item, indentLevel + 1);
				}
				indentLevel--;
				indent();
			}
			else if(inspecting.length < 5)
				foreach(idx, item; inspecting) {
					if(idx)
						terminal.write(", ");
					import std.conv; clicks[terminal.cursorY] = to!string(idx);
					drawItem(terminal, item, indentLevel + 1);
				}
			else
				terminal.writef("... %d items ...", inspecting.length);
			terminal.write("]");
		break;
		case var.Type.Integral:
		case var.Type.Floating:
		case var.Type.Boolean:
		case var.Type.Function:
			terminal.write(inspecting);
	}
}

/*
	inspect(obj)
		loads that object into the inspection window
	expand("path")
		expands the given object path in the inspection window


	http_client
		maintains cookies
		relative url


	http_transaction
		request
			method
			path
			queryArgs
			cookies
			rawHeaders (a array of strings)
			headers (an object)
			rawContent (a string)
			content (parsed into an object according to content-type)
		response
			headers
			cookies
			rawContent
			content
*/
