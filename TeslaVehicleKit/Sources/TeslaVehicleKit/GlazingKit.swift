import Foundation
import RealityKit
import simd

enum PaneRole:String,Decodable {
    case windshield,door,privacy,roof,backlight,quarter,tintedBack,tintedQuarter
    // Linear single-pass transmission of the substrate before the interfaces.
    // Studio matches, not specifications or legal tint measurements.
    var optical:SIMD4<Float>{
        switch self{
        case .windshield:return [0.865,0.945,0.92,0]
        case .door:return [0.79,0.895,0.855,1]
        case .privacy:return [0.145,0.225,0.208,2]
        case .roof:return [0.033,0.060,0.071,3]
        case .backlight:return [0.74,0.84,0.805,4]
        case .quarter:return [0.75,0.86,0.815,5]
        case .tintedBack:return [0.16,0.24,0.214,4]
        case .tintedQuarter:return [0.145,0.215,0.197,5]
        }
    }
}

@MainActor final class GlazingKit {
    struct Piece {
        enum Surface {
            case window(PaneRole, edge: URL, span: SIMD2<Float>)
            case lamp(LampLens)
        }
        let mesh: MeshResource
        let surface: Surface

        var optical: SIMD4<Float> {
            switch surface {
            case .window(let role, _, _): return role.optical
            case .lamp(let lens): return SIMD4(lens.substrate, lens.substrate, lens.substrate, 6)
            }
        }
        var shadowKind: UInt32 {
            switch surface {
            case .window(.roof, _, _): return 3
            case .window(.privacy, _, _), .window(.tintedBack, _, _), .window(.tintedQuarter, _, _): return 2
            default: return 1
            }
        }
    }
    struct Mounted {let front:Entity;let back:Entity?;let pieces:[Piece]}
    struct Trim {let base:MeshResource?;let details:[String:MeshResource]}
    private struct Files:Decodable{
        struct Pane:Decodable{let mesh,edge:String;let span:SIMD2<Float>;let role:PaneRole}
        struct Accent:Decodable{let base:String?;let details:[String:String]}
        let panes:[String:[Pane]],accents:[String:Accent]
    }
    let panes:[String:[Piece]],accents:[String:Trim]
    let directory:URL
    init(fleet:URL,car:VehicleScene)async throws{
        let dir=fleet.appendingPathComponent("Northlight/Glazing");directory=dir
        let files=try JSONDecoder().decode(Files.self,from:Data(contentsOf:car.directory.appendingPathComponent("Glazing.json")))
        let bank=try await Entity(contentsOf:dir.appendingPathComponent(car.manifest.model+".usdc"))
        var meshes=[String:MeshResource]()
        func walk(_ e:Entity){if let m=e.components[ModelComponent.self]{meshes[e.name]=m.mesh};for c in e.children{walk(c)}}
        walk(bank)
        func mesh(_ id:String)throws->MeshResource{guard let m=meshes[id] else{throw VehicleError.invalid("Missing window component \(id)")};return m}
        panes=try files.panes.mapValues{try $0.map{v in .init(mesh:try mesh(v.mesh),surface:.window(v.role,edge:dir.appendingPathComponent(v.edge),span:v.span))}}
        accents=try files.accents.mapValues{v in try .init(base:v.base.map(mesh),details:v.details.mapValues(mesh))}
        guard !panes.isEmpty else{throw VehicleError.invalid("No automotive glazing on \(car.manifest.model)")}
    }
}
