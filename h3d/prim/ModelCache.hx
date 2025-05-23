package h3d.prim;

typedef HideProps = {
	var animations : haxe.DynamicAccess<{ events : Array<{ frame : Int, data : String }> }>;
}

class ModelCache {

	var models : Map<String, { lib : hxd.fmt.hmd.Library, props : HideProps, col : Array<h3d.col.TransformCollider>, lastTime : Float }>;
	var textures : Map<String, h3d.mat.Texture>;
	var anims : Map<String, h3d.anim.Animation>;

	public function new() {
		models = new Map();
		textures = new Map();
		anims = new Map();
	}

	public function dispose() {
		for( m in models )
			m.lib.dispose();
		for( t in textures )
			t.dispose();
		anims = new Map();
		models = new Map();
		textures = new Map();
	}

	public function loadLibrary(res) : hxd.fmt.hmd.Library {
		return loadLibraryData(res).lib;
	}

	function loadLibraryData( res : hxd.res.Model ) {
		var path = res.entry.path;
		var m = models.get(path);
		if( m == null ) {
			var props = try {
				var parts = path.split(".");
				parts.pop();
				parts.push("props");
				var propsRes = hxd.res.Loader.currentInstance.load(parts.join("."));
				propsRes.watch(() -> {
					// Clear this anim cache so the anim and it's props are reloaded the next time they are requested
					models.remove(path);
					anims.remove(path);
				});
				haxe.Json.parse(propsRes.toText());
			} catch( e : hxd.res.NotFound )
				null;
			m = { lib : res.toHmd(), props : props, col : null, lastTime : 0. };
			models.set(path, m);
		}
		m.lastTime = haxe.Timer.stamp();
		return m;
	}

	public function loadModel( res : hxd.res.Model ) : h3d.scene.Object {
		var m = loadLibraryData(res);
		return m.lib.makeObject(texturePath -> loadTexture(res, texturePath));
	}

	public function loadCollider( res : hxd.res.Model ) {
		var m = loadLibraryData(res);
		var lib = m.lib;
		if( m.col == null ) {
			var colliders = [];
			for( m in lib.header.models ) {
				if( m.geometry < 0 ) continue;
				var prim = @:privateAccess lib.makePrimitive(m);
				if (prim == null)
					continue;
				var pos = m.position.toMatrix();
				var parent = lib.header.models[m.parent];
				while( parent != null ) {
					var pp = parent.position.toMatrix();
					pos.multiply3x4(pos, pp);
					parent = lib.header.models[parent.parent];
				}
				var col = cast(prim.getCollider(), h3d.col.Collider.OptimizedCollider);
				colliders.push(new h3d.col.TransformCollider(pos,col));
			}
			m.col = colliders;
		}
		return m.col;
	}

	public function loadTexture( model : hxd.res.Model, texturePath, async = false ) : h3d.mat.Texture {
		var fullPath = texturePath;
		if(model != null)
			fullPath = model.entry.path + "@" + fullPath;
		var t = textures.get(fullPath);
		if( t != null )
			return t;
		var tres;
		try {
			tres = hxd.res.Loader.currentInstance.load(texturePath);
		} catch( error : hxd.res.NotFound ) {
			if(model == null)
				throw error;
			// try again to load into the current model directory
			var path = model.entry.directory;
			if( path != "" ) path += "/";
			path += texturePath.split("/").pop();
			try {
				tres = hxd.res.Loader.currentInstance.load(path);
			} catch( e : hxd.res.NotFound ) try {
				// if this still fails, maybe our first letter is wrongly cased
				var name = path.split("/").pop();
				var c = name.charAt(0);
				if(c == c.toLowerCase())
					name = c.toUpperCase() + name.substr(1);
				else
					name = c.toLowerCase() + name.substr(1);
				path = path.substr(0, -name.length) + name;
				tres = hxd.res.Loader.currentInstance.load(path);
			} catch( e : hxd.res.NotFound ) {
				// force good path error
				throw error + (model != null ? " fullpath : " + fullPath : "");
			}
		}
		var img = tres.toImage();
		img.enableAsyncLoading = async;
		t = img.toTexture();
		textures.set(fullPath, t);
		return t;
	}

	public function loadAnimation( anim : hxd.res.Model, ?name : String, ?forModel : hxd.res.Model ) : h3d.anim.Animation {
		var path = anim.entry.path;
		if( name != null ) path += ":" + name;
		var a = anims.get(path);
		if( a != null )
			return a;
		a = initAnimation(anim,name,forModel);
		anims.set(path, a);
		return a;
	}

	function setAnimationProps( a : h3d.anim.Animation, resName : String, props : HideProps ) {
		if( props == null || props.animations == null ) return;
		var n = props.animations.get(resName);
		if( n != null && n.events != null )
			a.setEvents(n.events);
	}

	function initAnimation( res : hxd.res.Model, name : String, ?forModel : hxd.res.Model ) {
		var m = loadLibraryData(res);
		var a = m.lib.loadAnimation(name);
		setAnimationProps(a, res.name, m.props);
		if( forModel != null ) {
			var m = loadLibraryData(forModel);
			setAnimationProps(a, res.name, m.props);
		}
		return a;
	}

	public function cleanModels( lastUseTime = 180 ) {
		var now = haxe.Timer.stamp();
		var lastT = now - lastUseTime;
		for( m in models ) {
			if( m.lastTime < lastT ) {
				var usedPrim = false;
				for( p in @:privateAccess m.lib.cachedPrimitives )
					if( p.refCount > 1 ) {
						usedPrim = true;
						break;
					}
				if( usedPrim )
					m.lastTime = now;
				else {
					models.remove(m.lib.resource.entry.path);
					m.lib.dispose();
				}
			}
		}
	}

	public function refreshLodConfig() {
		for ( model in models )
			for ( p in @:privateAccess model.lib.cachedPrimitives ) {
				if ( p == null )
					continue;
				@:privateAccess p.lodConfig = null;
			}
	}

	#if hide

	public function loadPrefab( res : hxd.res.Prefab, ?p : hrt.prefab.Prefab, ?parent : h3d.scene.Object ) {
		if( p == null )
			p = res.load();
		var prevChild = 0;
		var local3d = null;
		if( parent != null ) {
			prevChild = parent.numChildren;
			local3d = parent;
		} else {
			local3d = new h3d.scene.Object();
		}
		var sh = new hrt.prefab.ContextShared(res.entry.path, p?.findFirstLocal2d(), local3d);
		var ctx2 = p.make(sh);
		if( parent != null ) {
			// only return object if a single child was added
			// if not - multiple children were added and cannot be returned as a single object
			return parent.numChildren == prevChild + 1 ? parent.getChildAt(prevChild) : null;
		}
		if( local3d.numChildren == 1 ) {
			// if we have a single root with no scale/rotate/offset we can return it
			var obj = local3d.getChildAt(0);
			if( obj.getTransform().isIdentity() )
				return obj;
		}
		return local3d;
	}

	#end
}