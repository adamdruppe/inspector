/**
	This is an interactive json inspector program.

	By Adam D. Ruppe, December 22, 2014.
*/


import terminal;

import arsd.script;
import arsd.http2;

import std.stdio;

string lastLine;
HttpClient client;

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
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

	auto client = new HttpClient();
	.client = client;

	auto lineGetter = new LineGetter(&terminal, "json-inspect");
	scope(exit) lineGetter.dispose();
	terminal.moveTo(0, terminal.height - 1);
	lineGetter.startGettingLine();

	version(sample)
	drawInspectionWindow(&terminal, json!q{
		"test":"string!",
		"int":100,
		"float":1.35,
		"array":[1,2,3],
		"object": {
			"str":"foo",
			"subnumber":12,
			"longarray": [1,2,3,4,5,6,7,8,9,1,2,3,4,5,5,6,4,23,343,234,234,23,423,3]
		},
		"null":null,
		"bool1":true,
		"bool2":false,
		"objarr":[
			{"id":12,"name":"twelve"},
			{"id":12,"name":"twelve"},
			{"id":12,"name":"twelve"}
		],
		"rls":"really long string that wouldn't be easy to ready becasuse it would wrap and fill up all the nonsense and hate the hatred"
	});

	bool running = true;

	var globals = var.emptyObject;

	globals.inspectionStack = [];
	globals.pushInspection = delegate var(var i) {
		globals.inspectionStack ~= i;
		globals.inspecting = i;
		return i;
	};

	globals.popInspection = delegate var() {
		var i = globals.inspectionStack[$-1];
		globals.inspectionStack = globals.inspectionStack[0 .. $-1];
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
			case InputEvent.Type.CharacterEvent:
				auto ev = event.get!(InputEvent.Type.CharacterEvent);
				if(ev.character == ('x' - 'a' + 1)) {
					// ctrl+x is a shortcut to open a json literal in the script lang
					lineGetter.addString("json!q{");
					lineGetter.redraw();
					break;
				}
			default:
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

	terminal.write("[<<] [>>]  || ");
	terminal.write(client.location);
	terminal.write(" || ");
	terminal.writeln(lastLine);

	foreach(i; 0 .. terminal.width)
		terminal.write("-");

	//terminal.moveTo(0, 2);

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
				int count = inspecting._object._properties.length;
				int showing = 0;
				foreach(k, v; inspecting) {
					indent();
					terminal.write(k);
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
					drawItem(terminal, item, indentLevel + 1);
				}
				indentLevel--;
				indent();
			}
			else if(inspecting.length < 5)
				foreach(idx, item; inspecting) {
					if(idx)
						terminal.write(", ");
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
