MODULE HLOCAL
  USE SCIFOR
  implicit none
  private

  integer,save                     :: Ns       !Number of levels per spin
  integer,save                     :: Ns_Ud
  integer,save                     :: Ns_Orb
  integer,save                     :: Nspin,Norb
  integer,save                     :: Nfock    !Dim of the local Fock space
  integer,save                     :: Nsectors !Number of sectors
  integer,allocatable,dimension(:) :: getDim             ! [Nsectors]
  logical                          :: hfmode=.true.

  !---------------- SECTOR-TO-LOCAL-FOCK SPACE STRUCTURE -------------------!
  type sector_map
     integer,dimension(:),allocatable          :: map
     logical                                   :: status=.false.
  end type sector_map

  type local_fock_sector
     integer                                   :: index       !
     type(sector_map),dimension(:),allocatable :: H
     integer,dimension(:),allocatable          :: DimUps
     integer,dimension(:),allocatable          :: DimDws
     integer                                   :: DimUp
     integer                                   :: DimDw
     integer                                   :: Dim
     integer,dimension(:),allocatable          :: Nups
     integer,dimension(:),allocatable          :: Ndws
     integer                                   :: Nup
     integer                                   :: Ndw
     logical                                   :: status=.false.
  end type local_fock_sector

  interface map_allocate
     module procedure :: map_allocate_scalar
     module procedure :: map_allocate_vector
  end interface map_allocate

  interface map_deallocate
     module procedure :: map_deallocate_scalar
     module procedure :: map_deallocate_vector
  end interface map_deallocate


  public :: Init_LocalFock_Sectors
  public :: Build_Hlocal_operator
  public :: Build_C_Operator
  public :: Build_Cdg_Operator
  public :: Build_Dens_Operator
  public :: Build_Docc_Operator


contains




  !##################################################################
  !##################################################################
  !               CREATE THE LOCAL FOCK SPACE
  !##################################################################
  !##################################################################
  subroutine Init_LocalFock_Sectors(Norb_,Nspin_)
    integer :: Nspin_,Norb_
    integer :: DimUp,DimDw
    integer :: DimUps(1),DimDws(1)
    integer :: Nups(1),Ndws(1)
    integer :: isector
    !
    Norb     = Norb_
    Nspin    = Nspin_
    Ns       = Norb
    Ns_Orb   = Ns
    Ns_Ud    = 1
    Nfock    = (2**Ns)*(2**Ns)
    Nsectors = ((Ns_Orb+1)*(Ns_Orb+1))**Ns_Ud
    !
    write(*,"(A)")"Init Local Fock space:"
    write(*,"(A,I15)") '# of levels           = ',Ns
    write(*,"(A,I15)") 'Fock space dimension  = ',Nfock
    write(*,"(A,I15)") 'Number of sectors     = ',Nsectors
    write(*,"(A)")"--------------------------------------------"
    !
    !Allocate some indexing arrays
    allocate(getDim(Nsectors))          ;getDim=0
    !
    !
    do isector=1,Nsectors
       call get_DimUp(isector,DimUps)
       call get_DimDw(isector,DimDws)
       DimUp = product(DimUps)
       DimDw = product(DimDws)  
       getDim(isector)  = DimUp*DimDw
    enddo
    !
    return
  end subroutine Init_LocalFock_Sectors





  !##################################################################
  !##################################################################
  !            BUILD LOCAL FOCK SPACE SECTORS (Nup,Ndw)
  !##################################################################
  !##################################################################
  subroutine Build_LocalFock_Sector(isector,self)
    integer,intent(in)                  :: isector
    type(local_fock_sector)             :: self
    integer                             :: iup,idw
    integer                             :: nup_,ndw_
    integer                             :: dim,iud
    !
    if(self%status)call Delete_LocalFock_Sector(self)
    !
    self%index = isector
    !
    allocate(self%H(Ns_Ud))
    allocate(self%DimUps(Ns_Ud))
    allocate(self%DimDws(Ns_Ud))
    allocate(self%Nups(Ns_Ud))
    allocate(self%Ndws(Ns_Ud))
    !
    call get_Nup(isector,self%Nups);self%Nup=sum(self%Nups)
    call get_Ndw(isector,self%Ndws);self%Ndw=sum(self%Ndws)
    call get_DimUp(isector,self%DimUps);self%DimUp=product(self%DimUps)
    call get_DimDw(isector,self%DimDws);self%DimDw=product(self%DimDws)
    self%Dim=self%DimUp*self%DimDw
    !

    call map_allocate(self%H,[self%DimUps])
    !
    dim=0
    do idw=0,2**Ns-1
       ndw_= popcnt(idw)
       if(ndw_ /= self%Ndws(1))cycle
       do iup=0,2**Ns-1
          nup_ = popcnt(iup)
          if(nup_ /= self%Nups(1))cycle
          dim      = dim+1
          self%H(1)%map(dim) = iup + idw*2**Ns
       enddo
    enddo
    !
    self%status=.true.
    !
  end subroutine Build_LocalFock_Sector


  subroutine Delete_LocalFock_Sector(self)
    type(local_fock_sector) :: self
    call map_deallocate(self%H)
    if(allocated(self%H))deallocate(self%H)
    if(allocated(self%DimUps))deallocate(self%DimUps)
    if(allocated(self%DimDws))deallocate(self%DimDws)
    if(allocated(self%Nups))deallocate(self%Nups)
    if(allocated(self%Ndws))deallocate(self%Ndws)
    self%index=0
    self%DimUp=0
    self%DimDw=0
    self%Dim=0
    self%Nup=0
    self%Ndw=0
    self%status=.false.
  end subroutine Delete_LocalFock_Sector






  !##################################################################
  !##################################################################
  !               BUILD LOCAL FOCK OPERATORS
  !##################################################################
  !##################################################################
  !+-------------------------------------------------------------------+
  !PURPOSE: 
  !+-------------------------------------------------------------------+
  function build_Hlocal_operator(hloc,xmu,uloc) result(Hmat)
    real(8),dimension(:,:,:)           :: hloc ![Nspin,Ns,Ns]
    real(8)                            :: xmu,uloc
    type(local_fock_sector)            :: sectorI
    real(8),dimension(:,:),allocatable :: Hmat
    real(8)                            :: htmp
    integer                            :: isector,i,m,io,jo
    integer                            :: iup,idw,mup,mdw
    integer                            :: nup(Ns),ndw(Ns),nvec(2*Ns)
    !
    if(allocated(Hmat))deallocate(Hmat)
    allocate(Hmat(Nfock,Nfock))
    !
    call assert_shape(Hloc,[Nspin,Ns,Ns],"build_hlocal_operator","Hloc")
    !
    !
    Hmat=0d0
    do isector=1,Nsectors
       call Build_LocalFock_Sector(isector,SectorI)
       do i=1,sectorI%Dim
          m    = sectorI%H(1)%map(i)
          nvec = bdecomp(m,2*Ns)
          nup  = nvec(1:Ns)
          ndw  = nvec(Ns+1:2*Ns)
          m    = m+1
          !
          htmp = 0d0
          !LOCAL HAMILTONIAN PART:
          htmp = htmp - xmu*(sum(nup)+sum(ndw))
          do io=1,Ns
             htmp = htmp + Hloc(1,io,io)*nup(io)
             htmp = htmp + Hloc(Nspin,io,io)*ndw(io)
          enddo
          !        
          Hmat(m,m)=Hmat(m,m) + htmp
          !
          !Density-density interaction: same orbital, opposite spins
          !Euloc=\sum=i U_i*(n_u*n_d)_i
          htmp = 0d0
          do io=1,Ns
             htmp = htmp + Uloc*nup(io)*ndw(io)
          enddo
          !
          if(Norb>1)then
             !density-density interaction: different orbitals, opposite spins:
             ! =   U'   *     sum_{i/=j} [ n_{i,up}*n_{j,dw} + n_{j,up}*n_{i,dw} ]
             do io=1,Ns
                do jo=io+1,Ns
                   htmp = htmp + (Uloc-2*0d0)*(nup(io)*ndw(jo) + nup(jo)*ndw(io))
                enddo
             enddo
             !density-density interaction: different orbitals, parallel spins
             ! = \sum_{i<j}    U''     *[ n_{i,up}*n_{j,up} + n_{i,dw}*n_{j,dw} ]
             do io=1,Ns
                do jo=io+1,Ns
                   htmp = htmp + (Uloc-3*0d0)*(nup(io)*nup(jo) + ndw(io)*ndw(jo))
                enddo
             enddo
          endif
          !if using the Hartree-shifted chemical potential: mu=0 for half-filling
          !sum up the contributions of hartree terms:
          if(hfmode)then
             do io=1,Ns
                htmp = htmp - 0.5d0*Uloc*(nup(io)+ndw(io))
             enddo
             if(Norb>1)then
                do io=1,Ns
                   do jo=io+1,Ns
                      htmp=htmp-0.5d0*(Uloc-2*0d0)*(nup(io)+ndw(io)+nup(jo)+ndw(jo))
                      htmp=htmp-0.5d0*(Uloc-3*0d0)*(nup(io)+ndw(io)+nup(jo)+ndw(jo))
                   enddo
                enddo
             endif
          endif
          !
          Hmat(m,m)=Hmat(m,m) + htmp
       enddo
       call Delete_LocalFock_Sector(sectorI)
    enddo
  end function build_hlocal_operator





  function build_C_operator(isite,ispin) result(Cmat)
    integer                            :: ispin,isite
    type(local_fock_sector)            :: sectorI
    real(8),dimension(:,:),allocatable :: Cmat
    real(8)                            :: c_
    integer                            :: imp,isector,i,min,mout
    integer                            :: nvec(2*Ns)
    !
    if(allocated(Cmat))deallocate(Cmat)
    allocate(Cmat(Nfock,Nfock))
    if(isite<1.OR.isite>Ns)stop "build_C_operator error: isite<1 OR isite>Ns. check."
    !
    imp = isite+(ispin-1)*Ns
    !
    Cmat=0d0
    do isector=1,Nsectors
       call Build_LocalFock_Sector(isector,SectorI)
       do i=1,sectorI%Dim
          min  = sectorI%H(1)%map(i)
          nvec = bdecomp(min,2*Ns)
          if(nvec(imp) == 0) cycle
          call c(imp,min,mout,c_)          
          Cmat(mout+1,min+1) = c_
       enddo
       call Delete_LocalFock_Sector(sectorI)
    enddo
  end function build_c_operator


  function build_Cdg_operator(isite,ispin) result(CDGmat)
    integer                            :: ispin,isite
    type(local_fock_sector)            :: sectorI
    real(8),dimension(:,:),allocatable :: CDGmat
    real(8)                            :: cdg_
    integer                            :: imp,isector,i,min,mout
    integer                            :: nvec(2*Ns)
    !
    if(allocated(CDGmat))deallocate(CDGmat)
    allocate(CDGmat(Nfock,Nfock))
    if(isite<1.OR.isite>Ns)stop "build_CDG_operator error: isite<1 OR isite>Ns. check."
    !
    imp = isite+(ispin-1)*Ns
    !
    CDGmat=0d0
    do isector=1,Nsectors
       call Build_LocalFock_Sector(isector,SectorI)
       do i=1,sectorI%Dim
          min  = sectorI%H(1)%map(i)
          nvec = bdecomp(min,2*Ns)
          if(nvec(imp) == 1) cycle
          call cdg(imp,min,mout,cdg_)          
          CDGmat(mout+1,min+1) = cdg_
       enddo
       call Delete_LocalFock_Sector(sectorI)
    enddo
  end function build_cdg_operator


  function build_Dens_operator(isite,ispin) result(Dmat)
    integer                            :: ispin,isite
    type(local_fock_sector)            :: sectorI
    real(8),dimension(:,:),allocatable :: Dmat
    real(8)                            :: dens
    integer                            :: imp,isector,i,m
    integer                            :: nvec(2*Ns)
    !
    if(allocated(Dmat))deallocate(Dmat)
    allocate(Dmat(Nfock,Nfock))
    if(isite<1.OR.isite>Ns)stop "build_Dens_operator error: isite<1 OR isite>Ns. check."
    !
    imp = isite+(ispin-1)*Ns
    !
    Dmat=0d0
    do isector=1,Nsectors
       call Build_LocalFock_Sector(isector,SectorI)
       do i=1,sectorI%Dim
          m    = sectorI%H(1)%map(i)
          nvec = bdecomp(m,2*Ns)
          dens = dble(nvec(imp))
          Dmat(m+1,m+1) = dens
       enddo
       call Delete_LocalFock_Sector(sectorI)
    enddo
  end function build_dens_operator


  function build_Docc_operator(isite) result(Dmat)
    integer                            :: isite
    type(local_fock_sector)            :: sectorI
    real(8),dimension(:,:),allocatable :: Dmat
    real(8)                            :: n_up,n_dw
    integer                            :: imp_up,imp_dw,isector,i,m
    integer                            :: nvec(2*Ns)
    !
    if(allocated(Dmat))deallocate(Dmat)
    allocate(Dmat(Nfock,Nfock))
    if(isite<1.OR.isite>Ns)stop "build_docc_operator error: isite<1 OR isite>Ns. check."
    !Put IF condition on isite value: isite=1,...,Ns
    imp_up = isite
    imp_dw = isite + Ns
    !
    Dmat=0d0
    do isector=1,Nsectors
       call Build_LocalFock_Sector(isector,SectorI)
       do i=1,sectorI%Dim
          m    = sectorI%H(1)%map(i)
          nvec = bdecomp(m,2*Ns)
          n_up = dble(nvec(imp_up))
          n_dw = dble(nvec(imp_dw))
          Dmat(m+1,m+1) = n_up*n_dw
       enddo
       call Delete_LocalFock_Sector(sectorI)
    enddo
  end function build_docc_operator












  !##################################################################
  !##################################################################
  !               RETRIEVE INFO PROCEDURES: Nup,Ndw,DimUp,DimDw
  !##################################################################
  !##################################################################
  subroutine get_Nup(isector,Nup)
    integer              :: isector,Nup(1)
    integer              :: i,count
    integer,dimension(2) :: indices_
    count=isector-1
    do i=1,2
       indices_(i) = mod(count,Ns+1)
       count      = count/(Ns+1)
    enddo
    Nup = indices_(2:2:-1)
  end subroutine get_Nup


  subroutine get_Ndw(isector,Ndw)
    integer              :: isector,Ndw(1)
    integer              :: i,count
    integer,dimension(2) :: indices_
    count=isector-1
    do i=1,2
       indices_(i) = mod(count,Ns+1)
       count      = count/(Ns+1)
    enddo
    Ndw = indices_(1:1:-1)
  end subroutine get_Ndw


  subroutine  get_DimUp(isector,DimUps)
    integer                :: isector,DimUps(1)
    integer                :: Nups(1)
    call get_Nup(isector,Nups)
    DimUps(1) = binomial(Ns,Nups(1))
  end subroutine get_DimUp


  subroutine get_DimDw(isector,DimDws)
    integer                :: isector,DimDws(1)
    integer                :: Ndws(1)
    call get_Ndw(isector,Ndws)
    DimDws(1) = binomial(Ns,Ndws(1))
  end subroutine get_DimDw


  subroutine indices2state(ivec,Nvec,istate)
    integer,dimension(:)          :: ivec
    integer,dimension(size(ivec)) :: Nvec
    integer                       :: istate,i
    istate=ivec(1)
    do i=2,size(ivec)
       istate = istate + (ivec(i)-1)*product(Nvec(1:i-1))
    enddo
  end subroutine indices2state

  subroutine state2indices(istate,Nvec,ivec)
    integer                       :: istate
    integer,dimension(:)          :: Nvec
    integer,dimension(size(Nvec)) :: Ivec
    integer                       :: i,count,N
    count = istate-1
    N     = size(Nvec)
    do i=1,N
       Ivec(i) = mod(count,Nvec(i))+1
       count   = count/Nvec(i)
    enddo
  end subroutine state2indices


  function iup_index(i,DimUp) result(iup)
    integer :: i
    integer :: DimUp
    integer :: iup
    iup = mod(i,DimUp);if(iup==0)iup=DimUp
  end function iup_index


  function idw_index(i,DimUp) result(idw)
    integer :: i
    integer :: DimUp
    integer :: idw
    idw = (i-1)/DimUp+1
  end function idw_index




  !##################################################################
  !##################################################################
  !               CREATION / DESTRUCTION OPERATORS
  !##################################################################
  !##################################################################
  !+-------------------------------------------------------------------+
  !PURPOSE: input state |in> of the basis and calculates 
  !   |out>=C_pos|in>  OR  |out>=C^+_pos|in> ; 
  !   the sign of |out> has the phase convention, pos labels the sites
  !+-------------------------------------------------------------------+
  subroutine c(pos,in,out,fsgn)
    integer,intent(in)    :: pos
    integer,intent(in)    :: in
    integer,intent(inout) :: out
    real(8),intent(inout) :: fsgn    
    integer               :: l
    if(.not.btest(in,pos-1))stop "C error: C_i|...0_i...>"
    fsgn=1d0
    do l=1,pos-1
       if(btest(in,l-1))fsgn=-fsgn
    enddo
    out = ibclr(in,pos-1)
  end subroutine c

  subroutine cdg(pos,in,out,fsgn)
    integer,intent(in)    :: pos
    integer,intent(in)    :: in
    integer,intent(inout) :: out
    real(8),intent(inout) :: fsgn    
    integer               :: l
    if(btest(in,pos-1))stop "C^+ error: C^+_i|...1_i...>"
    fsgn=1d0
    do l=1,pos-1
       if(btest(in,l-1))fsgn=-fsgn
    enddo
    out = ibset(in,pos-1)
  end subroutine cdg



  !##################################################################
  !##################################################################
  !               BITWISE OPERATIONS
  !##################################################################
  !##################################################################
  !+------------------------------------------------------------------+
  !PURPOSE  : input a state |i> and output a vector ivec(Nlevels)
  !with its binary decomposition
  !(corresponds to the decomposition of the number i-1)
  !+------------------------------------------------------------------+
  function bdecomp(i,Ntot) result(ivec)
    integer :: Ntot,ivec(Ntot),l,i
    logical :: busy
    !this is the configuration vector |1,..,Ns,Ns+1,...,Ntot>
    !obtained from binary decomposition of the state/number i\in 2^Ntot
    do l=0,Ntot-1
       busy=btest(i,l)
       ivec(l+1)=0
       if(busy)ivec(l+1)=1
    enddo
  end function bdecomp


  !+------------------------------------------------------------------+
  !PURPOSE  : input a vector ib(Nlevels) with the binary sequence 
  ! and output the corresponding state |i>
  !(corresponds to the recomposition of the number i-1)
  !+------------------------------------------------------------------+
  function bjoin(ib,Ntot) result(i)
    integer                 :: Ntot
    integer,dimension(Ntot) :: ib
    integer                 :: i,j
    i=0
    do j=0,Ntot-1
       i=i+ib(j+1)*2**j
    enddo
  end function bjoin





  !+------------------------------------------------------------------+
  !PURPOSE  : calculate the binomial factor n1 over n2
  !+------------------------------------------------------------------+
  elemental function binomial(n1,n2) result(nchoos)
    integer,intent(in) :: n1,n2
    real(8)            :: xh
    integer            :: i
    integer nchoos
    xh = 1.d0
    if(n2<0) then
       nchoos = 0
       return
    endif
    if(n2==0) then
       nchoos = 1
       return
    endif
    do i = 1,n2
       xh = xh*dble(n1+1-i)/dble(i)
    enddo
    nchoos = int(xh + 0.5d0)
  end function binomial



  !##################################################################
  !##################################################################
  !               MAP ALLOCATION/DESTRUCTION
  !##################################################################
  !##################################################################
  subroutine map_allocate_scalar(H,N)
    type(sector_map) :: H
    integer          :: N
    if(H%status) call map_deallocate_scalar(H)
    allocate(H%map(N))
    H%status=.true.
  end subroutine map_allocate_scalar
  !
  subroutine map_allocate_vector(H,N)
    type(sector_map),dimension(:)       :: H
    integer,dimension(size(H))          :: N
    integer                             :: i
    do i=1,size(H)
       call map_allocate_scalar(H(i),N(i))
    enddo
  end subroutine map_allocate_vector


  subroutine map_deallocate_scalar(H)
    type(sector_map) :: H
    if(.not.H%status)then
       write(*,*) "WARNING map_deallocate_scalar: H is not allocated"
       return
    endif
    if(allocated(H%map))deallocate(H%map)
    H%status=.false.
  end subroutine map_deallocate_scalar
  !
  subroutine map_deallocate_vector(H)
    type(sector_map),dimension(:) :: H
    integer                       :: i
    do i=1,size(H)
       call map_deallocate_scalar(H(i))
    enddo
  end subroutine map_deallocate_vector




END MODULE HLOCAL